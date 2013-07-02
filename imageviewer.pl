#!/usr/bin/perl -T
#
# @package img.ivacuum.ru
# @copyright (c) 2013 vacuum
#
use common::sense;
use DBI ();
use EV;
use Getopt::Long qw();
use IO::Socket::INET qw(IPPROTO_TCP TCP_NODELAY SO_LINGER SO_REUSEADDR SOL_SOCKET);
use Ivacuum::Utils;
use Ivacuum::Utils::DB;
use Ivacuum::Utils::HTTP;
use JSON qw(encode_json to_json);
require './cron.pm';
require './functions.pm';

# Отключение буферизации
$| = 1;

my($db, $s_accepted, $s_starttime) = (undef, 0, $^T);

# Настройки
my %g_cfg = (
  'db_host'  => '',
  'db_name'  => '',
  'db_user'  => '',
  'db_pass'  => '',
  'debug'    => 0,
  'ip'       => '0.0.0.0',
  'port'     => 2780,
  'sitename' => 'imageviewer',
);
my %g_opt = ('dev' => 0);
my %g_refs;
my %g_views;
my %g_views_from = ('internet' => 0, 'local' => 0);

load_json_config('config.json', \%g_cfg);
Getopt::Long::GetOptions(\%g_opt, 'dev');

# Особенные настройки для разрабатываемой версии
load_json_config('config.dev.json', \%g_cfg) if $g_opt{'dev'};

Ivacuum::Utils::set_debug_level($g_cfg{'debug'});
Ivacuum::Utils::set_sitename($g_cfg{'sitename'});
Ivacuum::Utils::DB::set_db_credentials($g_cfg{'db_host'}, $g_cfg{'db_name'}, $g_cfg{'db_user'}, $g_cfg{'db_pass'});
Ivacuum::Utils::DB::set_db(\$db);

# Подключение к БД
db_connect();

# Перезагрузка настроек
my $sighup = EV::signal 'HUP', sub {
  print_event('CORE', 'Получен сигнал: SIGHUP');
  load_json_config('config.json', \%g_cfg);
  load_json_config('config.dev.json', \%g_cfg) if $g_opt{'dev'};
  Ivacuum::Utils::set_debug_level($g_cfg{'debug'});
  Ivacuum::Utils::set_sitename($g_cfg{'sitename'});
  print_event('CORE', 'Настройки перезагружены');
  
  foreach my $key (keys %g_cfg) {
    print_event('CFG', $key . ': ' . $g_cfg{$key});
  }
};

# Принудительное завершение работы (Ctrl+C)
my $sigint = EV::signal 'INT', sub {
  imageviewer_shutdown('SIGINT', $g_opt{'dev'});
};

# Принудительное завершение работы (kill <pid>)
my $sigterm = EV::signal 'TERM', sub {
  imageviewer_shutdown('SIGTERM', $g_opt{'dev'});
};

# Создание сокета
my $fh = IO::Socket::INET->new(
  'Proto'     => 'tcp',
  'LocalAddr' => $g_cfg{'ip'},
  'LocalPort' => $g_cfg{'port'},
  'Listen'    => 50000,
  'ReuseAddr' => SO_REUSEADDR,
  'Blocking'  => 0,
) or die("\nНевозможно создать сокет: $!\n");
setsockopt $fh, IPPROTO_TCP, TCP_NODELAY, 1;
setsockopt $fh, SOL_SOCKET, SO_LINGER, pack('II', 1, 0);
setsockopt $fh, SOL_SOCKET, 0x1000, pack('Z16 Z240', 'httpready', '') if $^O eq 'freebsd';
print_event('CORE', 'Принимаем входящие пакеты по адресу ' . $g_cfg{'ip'} . ':' . $g_cfg{'port'});

my $ev_unixtime = int EV::now;

# Принимаем подключения
my $event = EV::io $fh, EV::READ, sub {
  my $session = $fh->accept() or return;
  
  # Клиент закрыл соединение
  return close_connection($session) unless $session->peerhost;

  # Неблокирующий режим работы
  $session->blocking(0);
  binmode $session;
  
  print_event('RECV', 'Подключился клиент ' . $session->peerhost . ':' . $session->peerport);

  # Чтение данных
  my $s_input = '';
  sysread $session, $s_input, 1024;

  $s_accepted++;
  print_event('CORE', 'Просмотров: ' . $s_accepted) if $s_accepted % 10000 == 0;
  
  $ev_unixtime = int EV::now;
  
  if ($s_input =~ /^(GET|HEAD) \/(g\/(\d{2})(\d{2})(\d{2})\/(s\/|t\/)?(\d+_[\da-zA-Z]{10}\.[a-z]{3,4})) HTTP/) {
    # Запрос картинки
    # /g/090205/t/1_NRcuHDbMyV.jpg HTTP/1.1
    my $path_old  = $2;
    my $date      = $3 . $4 . $5;
    my $date_new  = sprintf('%s/%s/%s', $3, $4, $5);
    my $subfolder = $6;
    my $url       = $7;

    my $path = sprintf('g/%s/%s%s', $date_new, $subfolder, $url);

    my $index    = $date . '/' . $url;
    my $provider = '';
    my $referer  = '';

    if ($s_input =~ /PROVIDER: ([a-z-]+)/) {
      $provider = $1;
    }

    if ($s_input =~ /Referer: (http|https):\/\/(www\.)?(.+?)(\.)?\//) {
      $referer = $5;
    }
    
    if ($provider ne 'internet') {
      $g_views_from{'local'}++;
    } else {
      $g_views_from{'internet'}++;
    }
    
    if (!-e '/srv/www/vhosts/static.ivacuum.ru/' . $path) {
      # Проверка наличия файла
      return http_not_found($session, $path_old);
    }

    if ($referer) {
      # Запоминаем ссылающийся сайт
      $g_refs{$referer} = 0 unless defined $g_refs{$referer};
      $g_refs{$referer}++;
    }

    if ($subfolder) {
      # Просмотр уменьшенной копии изображения
      if ($subfolder eq 's/') {
        # Счётчик просмотров
        $g_views{$index} = 0 unless defined $g_views{$index};
        $g_views{$index}++;
      }

      return http_redirect_internal($session, "/d/$path");
    }

    # Счётчик просмотров
    $g_views{$index} = 0 unless defined $g_views{$index};
    $g_views{$index}++;

    return http_redirect_internal($session, "/d/$path");
  } elsif ($g_cfg{'debug'} > 1 and $s_input =~ /^GET \/dumper HTTP/) {
    return html_msg($session, 'Дамп памяти', '<h3>g_views [' . (scalar keys %g_views) . ']</h3><pre>' . to_json(\%g_views, { pretty => 1 }) . '</pre><h3>g_refs [' . (scalar keys %g_refs) . ']</h3><pre>' . to_json(\%g_refs, { pretty => 1 }) . '</pre><h3>g_views_from</h3><pre>' . to_json(\%g_views_from, { pretty => 1 }) . '</pre>');
  } elsif ($s_input =~ /^GET \/favicon.ico HTTP/) {
    # GET /favicon.ico HTTP/1.1
    return http_not_found($session, 'favicon.ico');
  } elsif ($s_input =~ /^GET \/robots.txt HTTP/) {
    # GET /robots.txt HTTP/1.1
    return html_msg_simple($session, "User-agent: *\nDisallow: /\nHost: img.ivacuum.ru\n");
  } elsif ($s_input =~ /^GET \/stats HTTP/) {
    # Запрос статистики
    return html_msg($session, 'Статистика просмотрщика картинок', sprintf('<h3>Статистика</h3><p>Сервис работает %s.</p><p>Подключений обслужено: %s.</p>', date_format($ev_unixtime - $s_starttime), num_format($s_accepted)));
  } elsif ($s_input =~ /^GET \/ping HTTP/) {
    # Проверка отклика
    return html_msg_simple($session, "I'm alive! Don't worry.");
  } elsif ($s_input) {
    print_event('CORE', 'Request: ' . $s_input);
    return http_not_found($session, '');
  }
};

##
## CRON
##
my $cron = EV::timer 30, 30, sub {
  return if $g_opt{'dev'};
  
  $ev_unixtime = int EV::now;

  cron_update_views();
  cron_update_referers();
  cron_update_views_from();
};

EV::run;

#
# Ссылающиеся домены
#
sub cron_update_referers {
  my $sql_buffer = '';

  foreach my $index (keys %g_refs) {
    next unless $g_refs{$index};

    $sql_buffer = sprintf('%s%s("%s", %d)', $sql_buffer, ($sql_buffer ? ', ' : ''), $index, $g_refs{$index});

    $g_refs{$index} = 0;
  }

  my $sql = '
      INSERT INTO
          site_image_refs
      (ref_domain, ref_views) VALUES ' . $sql_buffer . '
      ON DUPLICATE KEY UPDATE
          ref_views = ref_views + values(ref_views)';
  &sql_do($sql) if $sql_buffer;
}

#
# Счетчик просмотров картинок
#
sub cron_update_views {
  &db_ping();
  
  my $sql = '
      UPDATE
          site_images
      SET
          image_views = image_views + ?,
          image_touch = ?
      WHERE
          image_date = ?
      AND
          image_url = ?';
  my $result = $db->prepare($sql);

  foreach my $index (keys %g_views) {
    # Начисляем просмотры
    my($date, $url) = split /\//, $index;

    # Обновление данных картинки
    $result->execute($g_views{$index}, $ev_unixtime, $date, $url);
    # &print_event('PIC', 'Картинке ' . $date . '/' . $url . ' +' . $g_views{$index} . ' просмотров');
  }

  %g_views = ();
}

#
# Количество просмотров из локальной сети и интернета
#
sub cron_update_views_from {
  my $sql_buffer = '';

  foreach my $index (keys %g_views_from) {
    next unless $g_views_from{$index};

    $sql_buffer = sprintf('%s%s("%s", %d)', $sql_buffer, ($sql_buffer ? ', ' : ''), $index, $g_views_from{$index});

    $g_views_from{$index} = 0;
  }

  my $sql = '
      INSERT INTO
          site_image_views
      (views_from, views_count) VALUES ' . $sql_buffer . '
      ON DUPLICATE KEY UPDATE
          views_count = views_count + values(views_count)';
  &sql_do($sql) if $sql_buffer;
}
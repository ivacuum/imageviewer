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

1;
sub imageviewer_shutdown {
  my($signal, $dev) = @_;

  print "\n";
  print_event('CORE', "Получен сигнал: $signal");
  EV::break;

  if (!$dev) {
    cron_update_views();
    cron_update_referers();
    cron_update_views_from();
    print_event('CORE', 'Задачи по расписанию выполнены');
  }

  db_disconnect();
  print_event('CORE', 'Успешное завершение сеанса связи с БД');
  print_event('CORE', 'Завершение работы...');
  exit 0;
}

1;
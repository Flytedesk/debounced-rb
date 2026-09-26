require 'rbconfig'
require 'socket'
require 'timeout'

module ServerHelpers
  def start_server(socket_path)
    log = File.open('debounce_server.log', 'a')
    pid = Process.spawn(RbConfig.ruby, '-Ilib', '-rdebounced', '-rdebounced/server',
                        '-e', 'Debounced::Server.new(ARGV[0]).listen', socket_path,
                        out: log, err: log)
    Timeout.timeout(5) { sleep 0.05 until File.socket?(socket_path) }
    pid
  end

  def stop_server(pid)
    Process.kill('TERM', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def write_message(connection, message)
    connection.write(JSON.generate(message), Debounced::ServiceProxy::DELIMITER)
  end

  def read_message(connection, timeout: 2)
    return unless connection.wait_readable(timeout)

    line = connection.gets(Debounced::ServiceProxy::DELIMITER, chomp: true)
    line && JSON.parse(line)
  end

  def debounce_message(descriptor, timeout: 0.1, kwargs: {})
    {
      type: 'debounceEvent',
      data: {
        descriptor:,
        timeout:,
        callback: { class_name: 'TestEvent', method_name: 'publish1', kwargs: }
      }
    }
  end
end

namespace :debounced do
  desc 'Start the debounce server'
  task server: :environment do
    require 'debounced'
    require 'debounced/server'

    Debounced::Server.new(Debounced.configuration.socket_descriptor).listen
  end
end

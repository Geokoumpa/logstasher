require 'active_support/core_ext/class/attribute'
require 'active_support/log_subscriber'

module LogStasher
  class RequestLogSubscriber < ActiveSupport::LogSubscriber
    def process_action(event)
      #unless event.payload[:action_black_list].include?('all') && event.payload[:action_white_list].blank?
      #binding.pry
      payload = event.payload

      make_black_list(payload)

      unless forbidden(payload)
        puts 'Logging ' + payload[:controller] + ' with action ' + payload[:action]
        data      = extract_request(payload)
        data.merge! extract_status(payload)
        data.merge! runtimes(event)
        data.merge! location(event)
        data.merge! extract_exception(payload)
        data.merge! extract_custom_fields(payload)
  
        tags = ['request']
        tags.push('exception') if payload[:exception]
        event = LogStash::Event.new(data.merge({'@source' => LogStasher.source, '@tags' => tags}))
        LogStasher.logger << event.to_json + "\n"
      else
        puts 'rejected ' + payload[:controller] + ' with action ' + payload[:action]
      end
    end
    
    def extract_custom_fields(payload)

      custom_fields = (!LogStasher.custom_fields.empty? && payload.extract!(*LogStasher.custom_fields - [:black_list] - [:white_list] - [:forbidden_params] - [:black_list_everything])) || {}
      LogStasher.custom_fields.clear
      custom_fields
    end 

    def make_black_list(payload)
      if payload[:black_list_everything]
        payload[:black_list] = {method: [payload[:method]], controller: {payload[:controller] => {actions: [payload[:action]]}}}
        # event.payload[:black_list][:method] = event.payload[:method]
        # event.payload[:black_list][:controller] = event.payload[:controller]
        # event.payload[:black_list][:action] = event.payload[:action]
      end  
    end 

    def forbidden(payload)

      white_list = payload[:white_list] || {method: [], controller: {}}  
      black_list = payload[:black_list] || {method: [], controller: {}}
      forbidden_params = payload[:forbidden_params] || {}
  
      if black_list[:method].include?(payload[:method])

        if (white_list[:controller][payload[:controller]] && white_list[:controller][payload[:controller]][:actions].include?(payload[:action])) or (white_list[:controller][payload[:controller]] == {actions: []}) or white_list[:method].include?(payload[:method])
          reject = false

        else
          reject = true
        end
      end
      reject ||=false


      unless reject


        reject = black_list[:controller].keys.include?(payload[:controller]) and !white_list[:controller].keys.include?(payload[:controller])
        if reject
          black_actions = black_list[:controller][payload[:controller]][:actions] || []
          white_list[:controller][payload[:controller]] ||= {}
          white_actions = white_list[:controller][payload[:controller]][:actions] || []
          reject = ((black_actions.include?(payload[:action]) and !white_actions.include?(payload[:action])) or (black_actions == [] and !white_actions.include?(payload[:action])))         
        end

        unless reject
          
          forbidden_params.keys.each do |key|
            found = (search_hash(payload, key) == forbidden_params[key])
            if found
              reject = found
              return  reject
            end
          end
          
        end
      end
      return reject
    end

    def search_hash(h, search)
      return h[search] if h.fetch(search, false)
    
      h.keys.each do |k|
        answer = search_hash(h[k], search) if h[k].is_a? Hash
        return answer if answer
      end
    
      false
    end



    def redirect_to(event)
      Thread.current[:logstasher_location] = event.payload[:location]
    end

    private

    def extract_request(payload)
      {
        :method => payload[:method],
        :path => extract_path(payload),
        :format => extract_format(payload),
        :controller => payload[:params]['controller'],
        :action => payload[:params]['action']
      }
    end

    def extract_path(payload)
      payload[:path].split("?").first
    end

    def extract_format(payload)
      if ::ActionPack::VERSION::MAJOR == 3 && ::ActionPack::VERSION::MINOR == 0
        payload[:formats].first
      else
        payload[:format]
      end
    end

    def extract_status(payload)
      if payload[:status]
        { :status => payload[:status].to_i }
      else
        { :status => 0 }
      end
    end

    def runtimes(event)
      {
        :duration => event.duration,
        :view => event.payload[:view_runtime],
        :db => event.payload[:db_runtime]
      }.inject({}) do |runtimes, (name, runtime)|
        runtimes[name] = runtime.to_f.round(2) if runtime
        runtimes
      end
    end

    def location(event)
      if location = Thread.current[:logstasher_location]
        Thread.current[:logstasher_location] = nil
        { :location => location }
      else
        {}
      end
    end

    # Monkey patching to enable exception logging
    def extract_exception(payload)
      if payload[:exception]
        exception, message = payload[:exception]
        status = ActionDispatch::ExceptionWrapper.status_code_for_exception(exception)
        message = "#{exception}\n#{message}\n#{($!.backtrace.join("\n"))}"
        { :status => status, :error => message }
      else
        {}
      end
    end

    def extract_custom_fields(payload)
      custom_fields = (!LogStasher.custom_fields.empty? && payload.extract!(*LogStasher.custom_fields)) || {}
      LogStasher.custom_fields.clear
      custom_fields
    end
  end

  class MailerLogSubscriber < ActiveSupport::LogSubscriber
    MAILER_FIELDS = [:mailer, :action, :message_id, :from, :to]

    def deliver(event)
      process_event(event, ['mailer', 'deliver'])
    end

    def receive(event)
      process_event(event, ['mailer', 'receive'])
    end

    def process(event)
      process_event(event, ['mailer', 'process'])
    end

    def logger
      LogStasher.logger
    end

    private

    def process_event(event, tags)
      data = LogStasher.request_context.merge(extract_metadata(event.payload))
      event = LogStash::Event.new('@source' => LogStasher.source, '@fields' => data, '@tags' => tags)
      logger << event.to_json + "\n"
    end

    def extract_metadata(payload)
      payload.slice(*MAILER_FIELDS)
    end
  end
end

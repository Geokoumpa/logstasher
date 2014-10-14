
require 'active_support/core_ext/class/attribute'
require 'active_support/log_subscriber'

module LogStasher
  class RequestLogSubscriber < ActiveSupport::LogSubscriber
    def process_action(event)


      payload = event.payload

      custom_fields = extract_custom_fields(payload)
      #make_black_list(payload)

      unless forbidden(payload) or custom_fields.blank?

        data      = extract_request(payload)

        data.merge! extract_status(payload)
        data.merge! runtimes(event)
        data.merge! location(event)
        data.merge! extract_exception(payload)
        data.merge! custom_fields
        data.merge!({timestamp: (Time.now.utc.to_f.round(3) *1000).to_i})
        tags = ['request']
        tags.push('exception') if payload[:exception]
        event = data
    
        LogStasher.logger << event.to_json + "\n"  

      end
    end
    
    def extract_custom_fields(payload)
      custom_fields = (!LogStasher.custom_fields.empty? && payload.extract!(*LogStasher.custom_fields - [:black_list_methods] - [:black_controllers] - [:forbidden_params] - [:white_controllers])) || {}
      custom_fields
    end 

 

    def forbidden(payload)

      b_c = payload[:black_controllers]
      w_c = payload[:white_controllers]
      con = payload[:controller]
      act = payload[:action]
      if payload[:black_list_methods]
        if payload[:black_list_methods].include?(payload[:method])
          reject = true

          if w_c.keys.include?(payload[:controller])
            if w_c[con][:actions].include?(act) or w_c[con][:actions].empty?
              reject = false
            end
          end
        else
          reject = false  

          if b_c.keys.include?(payload[:controller])
            if b_c[con][:actions].include?(act) or w_c[con][:actions].empty?
              reject = true
            end
          end
        end

        unless reject
          params = payload[:params]
          forbidden = payload[:forbidden_params]
          common_keys = params.keys & forbidden.keys
          common_keys.each do |key|
            if forbidden[key] == params[key]
              reject = true
              
            end
            break if reject
          end


        end
      else
        reject = true
      end

      return reject

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

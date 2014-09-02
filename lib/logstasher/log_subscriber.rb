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
      #puts 'white list is ' + white_list.to_s
      #puts 'black list is ' + black_list.to_s
      forbidden_params = payload[:forbidden_params] || {}
      #puts 'forbidden_params list is ' + forbidden_params.to_s  
      if black_list[:method].include?(payload[:method])

        if (white_list[:controller][payload[:controller]] && white_list[:controller][payload[:controller]][:actions].include?(payload[:action])) or (white_list[:controller][payload[:controller]] == {actions: []}) or white_list[:method].include?(payload[:method])
          reject = false

        else
          reject = true
        end
      end

      reject ||=false

      #puts 'reject is after method ' + reject.to_s
      unless reject


        reject = black_list[:controller].keys.include?(payload[:controller]) and !white_list[:controller].keys.include?(payload[:controller])
        #puts 'reject is after controller black check ' + reject.to_s
        if reject
          black_actions = black_list[:controller][payload[:controller]][:actions] || []
          white_list[:controller][payload[:controller]] ||= {}
          white_actions = white_list[:controller][payload[:controller]][:actions] || []
          reject = ((black_actions.include?(payload[:action]) and !white_actions.include?(payload[:action])) or (black_actions == [] and !white_actions.include?(payload[:action])))         
        end

        unless reject
          
          payload.delete(:forbidden_params)
          forbidden_params.keys.each do |key|
            found = (search_hash(payload, key) == forbidden_params[key])
            #puts 'reject is after params ' + reject.to_s + ' setting is ' + forbidden_params.to_s + ' params is ' + payload.to_s
            if found

              reject = found
              return  reject
            end
          end
          
        end
      end
      #puts 'reject final is  ' + reject.to_s
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




  end
end

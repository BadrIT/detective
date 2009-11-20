require 'ruby_parser'

module Detective

  ForkSupported = respond_to? :fork

	def self.view_source(method)
    location = get_location(method).strip.split /[\r\n]+/
    case location.first
      when 'native method' then return 'native method'
      when 'error' then raise location[1..-1].join(' ')
      when 'location' then
      begin
        filename, line_no = location[1,2] 
        line_no = line_no.to_i
        f = File.open filename
        source = ""
        file_line_no = 0
        rp = RubyParser.new
        f.each_line do |file_line|
          file_line_no += 1
          if file_line_no >= line_no
            source << file_line
            # Try to parse it to know whether the method is complete or not
            rp.parse(source) && break rescue nil
          end
        end
        f.close
        return source
      rescue
        return "Cannot find source code"
      end
    end
	end
	
	# Finds the location of a method in ruby source files
	# You can pass a string like
	# * 'Class.name' class method
	# # 'String#size' instance method
	def self.get_location(ruby_statement)
    if ruby_statement.index('#')
      # instance method
      class_name, method_name = ruby_statement.split('#')
      class_method = false
    elsif ruby_statement.index('.')
      class_name, method_name = ruby_statement.split('.')
      class_method = true
    else
      raise "Invalid parameter"
    end
    the_klass = eval(class_name)
    ForkSupported ? get_location_fork(the_klass, method_name, class_method) : get_location_thread(the_klass, method_name, class_method)
  end
  
private

  def self.get_location_thread(the_klass, method_name, class_method)
    if class_method
      raise "Invalid class method name #{method_name} for class #{the_klass}" unless the_klass.respond_to? method_name
    else
      raise "Invalid instance method name #{method_name} for class #{the_klass}" unless the_klass.instance_methods.include? method_name
    end
    result = ""
    t = Thread.new do
      # child process
      detective_state = 0
      # Get an instance of class Method that can be invoked using Method#call
      the_method, args = get_method(the_klass, method_name, class_method)
      set_trace_func(proc do |event, file, line, id, binding, classname|
        if id == :call
          detective_state = 1
          return
        end
        return if detective_state == 0
        if event == 'call'
          result << "location" << "\r\n"
          result << file << "\r\n"
          result << line.to_s << "\r\n"
          # Cancel debugging
          set_trace_func nil
          Thread.kill(Thread.current)
        elsif event == 'c-call'
          result << 'native method'
          set_trace_func nil
          Thread.kill(Thread.current)
        end
      end)

      begin
        the_method.call *args
        # If the next line executed, this indicates an error because the method should be cancelled before called
        result << "method called!" << "\r\n"
      rescue Exception => e
        result << "error" << "\r\n"
        result << e.inspect << "\r\n"
      end
    end
    t.join
    result
  end

  def self.get_location_fork(the_klass, method_name, class_method)
    f = open("|-", "w+")
    if f == nil
      # child process
      detective_state = 0
      # Get an instance of class Method that can be invoked using Method#call
      the_method, args = get_method(the_klass, method_name, class_method)
      set_trace_func(proc do |event, file, line, id, binding, classname|
        if id == :call
          detective_state = 1
          return
        end
        return if detective_state == 0
        if event == 'call'
          puts "location"
          puts file
          puts line
          set_trace_func nil
          exit!
        elsif event == 'c-call'
          puts 'native method'
          set_trace_func nil
          exit!
        end
      end)
      
      begin
        the_method.call *args
        # If the next line executed, this indicates an error because the method should be cancelled before called
        puts "method called!"
      rescue => e
        puts "error"
        puts e.inspect
      ensure
        exit!
      end
    else
      Process.wait
      x = f.read
#      puts x
      return x
    end
  end
  
  def self.get_method(the_klass, method_name, class_method)
    if class_method
      the_method = the_klass.method(method_name)
    else
      # Create a new empty initialize method to bypass initialization
      the_klass.class_eval do
        alias old_initialize initialize
        def initialize
          # Bypass initialization
        end
      end
      the_method = the_klass.new.method(method_name)
      # Revert initialize method
      the_klass.class_eval do
        # under causes a warning
#        undef initialize
        alias initialize old_initialize
      end
    end
    # check how many attributes are required
    the_method_arity = the_method.arity
    required_args = the_method_arity < 0 ? -the_method_arity-1 : the_method_arity
    
    # Return the method and its parameters
    [the_method, Array.new(required_args)]
  end

end

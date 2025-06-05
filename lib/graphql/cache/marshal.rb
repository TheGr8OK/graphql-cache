# frozen_string_literal: true

require 'graphql/cache/deconstructor'

module GraphQL
  module Cache
    # Used to marshal cache fetches into either writes or reads
    class Marshal
      # The cache key to marshal around
      #
      # @return [String] The cache key
      attr_accessor :key

      # Initializer helper to allow syntax like
      # `Marshal[key].read(config, &block)`
      #
      # @return [GraphQL::Cache::Marshal]
      def self.[](key)
        new(key)
      end

      # Initialize a new instance of {GraphQL::Cache::Marshal}
      def initialize(key)
        self.key = key.to_s
      end

      # Read a value from cache if it exists and re-hydrate it or
      # execute the block and write it's result to cache
      #
      # @param config [Hash] The object passed to `cache:` on the field definition
      # @return [Object]
      def read(config, force: false, &block)
        # write new data from resolver if forced
        return write(config, &block) if force

        cached = cache.read(key)

        if cached.nil?
          logger.debug "Cache miss: (#{key})"
          write config, &block
        else
          logger.debug "Cache hit: (#{key})"
          cached
        end
      end

      # Executes the resolution block and writes the result to cache
      #
      # @see GraphQL::Cache::Deconstruct#perform
      # @param config [Hash] The middleware resolution config hash
      def write(config)
        resolved = yield

        document = Deconstructor[resolved].perform

        with_resolved_document(document) do |resolved_document|
          # Try to cache the document, with fallback for non-serializable objects
          cache_document(resolved_document, config)
          resolved
        end
      end

      # @private
      def with_resolved_document(document)
        if document_is_lazy?(document)
          document.then { |promise_value| yield promise_value }
        else
          yield document
        end
      end

      # @private
      def document_is_lazy?(document)
        ['GraphQL::Execution::Lazy', 'Promise'].include?(document.class.name)
      end

      # @private
      def cache_document(document, config)
        cache.write(key, document, expires_in: expiry(config))
      rescue TypeError => e
        # Handle serialization errors by attempting to clean the document
        if e.message.include?('_dump_data') || e.message.include?('Proc')
          cleaned_document = clean_for_serialization(document)
          begin
            cache.write(key, cleaned_document, expires_in: expiry(config))
            logger.debug "Cache write successful after cleaning: (#{key})"
          rescue TypeError => clean_error
            logger.debug "Cache skip: (#{key}) - failed to serialize even after cleaning: #{clean_error.message}"
          end
        else
          logger.debug "Cache skip: (#{key}) - serialization error: #{e.message}"
        end
      end

      # @private  
      def clean_for_serialization(obj)
        case obj
        when Array
          obj.map { |item| clean_for_serialization(item) }
        when Hash
          obj.each_with_object({}) do |(k, v), cleaned|
            cleaned[k] = clean_for_serialization(v)
          end
        when Proc, Method, UnboundMethod
          # Replace non-serializable callables with nil or a placeholder
          nil
        else
          # For ActiveRecord objects and other complex objects, try to convert to basic types
          if obj.respond_to?(:attributes) && obj.respond_to?(:id)
            # ActiveRecord-like object - extract serializable attributes
            clean_active_record_object(obj)
          elsif obj.respond_to?(:to_h)
            clean_for_serialization(obj.to_h)
          elsif obj.respond_to?(:to_a)
            clean_for_serialization(obj.to_a)
          else
            # Return the object as-is and let Marshal handle it
            obj
          end
        end
      end

      # @private
      def clean_active_record_object(obj)
        # For ActiveRecord objects, extract the core attributes but avoid associations that might contain procs
        base_attrs = {}
        
        if obj.respond_to?(:attributes)
          obj.attributes.each do |key, value|
            base_attrs[key] = clean_for_serialization(value)
          end
        end
        
        # Add the ID if present
        base_attrs['id'] = obj.id if obj.respond_to?(:id)
        base_attrs['class'] = obj.class.name if obj.respond_to?(:class)
        
        base_attrs
      end

      # @private
      def expiry(config)
        if config.is_a?(Hash) && config[:expiry]
          config[:expiry]
        else
          GraphQL::Cache.expiry
        end
      end

      # @private
      def cache
        GraphQL::Cache.cache
      end

      # @private
      def logger
        GraphQL::Cache.logger
      end
    end
  end
end

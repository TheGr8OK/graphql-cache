# frozen_string_literal: true

require 'graphql/cache/deconstructor'
require 'set'

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
      def with_resolved_document(document, &block)
        if document_is_lazy?(document)
          document.then(&block)
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
          cleaned_document = clean_for_serialization(document, max_depth: 5, visited: Set.new)
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
      def clean_for_serialization(obj, max_depth: 5, visited: Set.new)
        # Prevent infinite recursion
        return nil if max_depth <= 0

        # Prevent circular references
        obj_id = obj.object_id
        return nil if visited.include?(obj_id)

        visited.add(obj_id)

        begin
          case obj
          when Array
            obj.map { |item| clean_for_serialization(item, max_depth: max_depth - 1, visited: visited) }.compact
          when Hash
            obj.each_with_object({}) do |(k, v), cleaned|
              cleaned_value = clean_for_serialization(v, max_depth: max_depth - 1, visited: visited)
              cleaned[k] = cleaned_value unless cleaned_value.nil?
            end
          when Proc, Method, UnboundMethod, Thread::Mutex
            # Replace non-serializable callables and thread objects with nil
            nil
          else
            # Handle ActiveRecord Collection Proxies first
            if obj.class.name.include?('CollectionProxy') || obj.class.name.include?('AssociationRelation')
              # Convert to array and clean each element
              begin
                array_items = obj.respond_to?(:to_a) ? obj.to_a : []
                array_items.map do |item|
                  clean_for_serialization(item, max_depth: max_depth - 1, visited: visited)
                end.compact
              rescue StandardError => e
                logger.debug "Failed to convert collection proxy to array: #{e.message}"
                []
              end
            elsif obj.respond_to?(:attributes) && obj.respond_to?(:id)
              # ActiveRecord-like object - extract serializable attributes
              clean_active_record_object(obj, max_depth: max_depth - 1, visited: visited)
            elsif obj.respond_to?(:to_h) && !dangerous_object?(obj)
              clean_for_serialization(obj.to_h, max_depth: max_depth - 1, visited: visited)
            elsif obj.respond_to?(:to_a) && !dangerous_object?(obj)
              clean_for_serialization(obj.to_a, max_depth: max_depth - 1, visited: visited)
            elsif obj.respond_to?(:as_json)
              # Try as_json for objects that support it (like many Rails objects)
              clean_for_serialization(obj.as_json, max_depth: max_depth - 1, visited: visited)
            elsif serializable_without_cleaning?(obj)
              # Return the object as-is if it's already serializable
              obj
            else
              # For complex objects that can't be easily cleaned, return a safe representation
              safe_object_representation(obj)
            end
          end
        ensure
          visited.delete(obj_id)
        end
      end

      # @private
      def dangerous_object?(obj)
        # Objects that should not be converted to hash/array as they may contain non-serializable data
        obj.class.name.match?(/Connection|Relation|AssociationRelation|Scope|Mutex|Thread|IO|File|Socket/)
      end

      # @private
      def serializable_without_cleaning?(obj)
        return false if obj.nil?

        # Check if basic types that are safe to serialize
        case obj
        when String, Integer, Float, TrueClass, FalseClass, NilClass, Symbol
          true
        when Time, Date, DateTime
          true
        else
          # For other objects, try a quick marshal test on a small sample
          begin
            ::Marshal.dump(obj)
            true
          rescue TypeError
            false
          end
        end
      end

      # @private
      def safe_object_representation(obj)
        # Create a safe representation of complex objects
        result = {}

        # Include basic identifiable information
        result['class'] = obj.class.name if obj.respond_to?(:class)
        result['id'] = obj.id if obj.respond_to?(:id) && !obj.id.nil?

        # For objects with a name or title
        if obj.respond_to?(:name) && !obj.name.nil?
          result['name'] = obj.name.to_s
        elsif obj.respond_to?(:title) && !obj.title.nil?
          result['title'] = obj.title.to_s
        end

        # Add timestamp if available
        if obj.respond_to?(:updated_at) && !obj.updated_at.nil?
          result['updated_at'] = obj.updated_at.to_s
        elsif obj.respond_to?(:created_at) && !obj.created_at.nil?
          result['created_at'] = obj.created_at.to_s
        end

        result.empty? ? nil : result
      end

      # @private
      def clean_active_record_object(obj, max_depth: 5, visited: Set.new)
        # Prevent infinite recursion
        return nil if max_depth <= 0

        # Prevent circular references
        obj_id = obj.object_id
        return nil if visited.include?(obj_id)

        visited.add(obj_id)

        begin
          base_attrs = {}

          if obj.respond_to?(:attributes)
            obj.attributes.each do |key, value|
              cleaned_value = clean_for_serialization(value, max_depth: max_depth - 1, visited: visited)
              base_attrs[key] = cleaned_value unless cleaned_value.nil?
            end
          end

          # Add the ID if present
          base_attrs['id'] = obj.id if obj.respond_to?(:id) && !obj.id.nil?
          base_attrs['class'] = obj.class.name if obj.respond_to?(:class)

          base_attrs
        rescue StandardError => e
          # If we can't safely extract attributes, fall back to safe representation
          logger.debug "Failed to clean ActiveRecord object #{obj.class}: #{e.message}"
          safe_object_representation(obj)
        ensure
          visited.delete(obj_id)
        end
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

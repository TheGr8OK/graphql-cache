# frozen_string_literal: true

module GraphQL
  module Cache
    # Represents the caching resolver that wraps the existing resolver proc
    class Resolver
      attr_accessor :type

      attr_accessor :field

      def initialize(type, field)
        @type  = type
        @field = field
      end

      def call(obj, args, ctx, &block)
        key = cache_key(obj, args, ctx)

        # Get cache config from field extension options or metadata (backward compatibility)
        cache_config = get_cache_config

        value = Marshal[key].read(
          cache_config, force: ctx[:force_cache]
        ) do
          block.call
        end

        wrap_connections(value, args, parent: obj, context: ctx)
      end

      protected

      # @private
      def cache_key(obj, args, ctx)
        Key.new(obj, args, type, field, ctx).to_s
      end

      # @private
      def get_cache_config
        # Try to get from instance variable first (GraphQL 2.x with extension)
        if field.instance_variable_defined?(:@cache_config)
          return field.instance_variable_get(:@cache_config)
        end
        
        # Try to get from extension options (GraphQL 2.x)
        if field.respond_to?(:extensions) && field.extensions.any? { |ext| ext.is_a?(GraphQL::Cache::Extension) }
          extension = field.extensions.find { |ext| ext.is_a?(GraphQL::Cache::Extension) }
          return extension.options[:cache] if extension
        end
        
        # Fallback to metadata for backward compatibility (GraphQL 1.x)
        field.metadata[:cache] if field.respond_to?(:metadata)
      end

      # @private
      def wrap_connections(value, args, **kwargs)
        # return raw value if field isn't a connection (no need to wrap)
        return value unless field.connection?

        # return cached value if it is already a connection object
        # this occurs when the value is being resolved by GraphQL
        # and not being read from cache
        return value if connection_object?(value)

        create_connection(value, args, **kwargs)
      end

      # @private
      def connection_object?(value)
        # Check for GraphQL 2.x connection classes
        return true if defined?(GraphQL::Pagination::Connection) && value.is_a?(GraphQL::Pagination::Connection)
        
        # Check for GraphQL 1.x connection classes (backward compatibility)
        if defined?(GraphQL::Relay::BaseConnection)
          return true if value.class.ancestors.include?(GraphQL::Relay::BaseConnection)
        end
        
        false
      end

      # @private
      def create_connection(value, args, **kwargs)
        # Use GraphQL 2.x pagination if available
        if defined?(GraphQL::Pagination::Connection)
          # In GraphQL 2.x, connections are created differently
          # The field should handle this automatically, so we just return the value
          return value
        end
        
        # Fallback to GraphQL 1.x connection creation for backward compatibility
        if defined?(GraphQL::Relay::BaseConnection)
          GraphQL::Relay::BaseConnection.connection_for_nodes(value).new(
            value,
            args,
            field: field,
            parent: kwargs[:parent],
            context: kwargs[:context]
          )
        else
          # If no connection classes are available, return the raw value
          value
        end
      end
    end
  end
end

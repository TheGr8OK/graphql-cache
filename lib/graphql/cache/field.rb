require 'graphql'
require 'graphql/cache/extension'

module GraphQL
  module Cache
    # Custom field class implementation to allow for
    # cache config keyword parameters
    class Field < ::GraphQL::Schema::Field
      # Overriden to take a new cache keyword argument
      def initialize(
        *args,
        cache: false,
        **kwargs,
        &block
      )
        @cache_config = cache
        super(*args, **kwargs, &block)
        
        # Add the cache extension if caching is enabled
        if @cache_config
          extension(GraphQL::Cache::Extension, cache: @cache_config)
        end
      end

      # Overriden to provide custom cache config to internal definition
      # This is kept for backward compatibility with GraphQL 1.x
      def to_graphql
        field_defn = super # Returns a GraphQL::Field
        field_defn.metadata[:cache] = @cache_config if field_defn.respond_to?(:metadata)
        field_defn
      end
    end
  end
end

# frozen_string_literal: true

require 'graphql/cache/resolver'

module GraphQL
  module Cache
    # Field extension that provides caching functionality for GraphQL fields
    # This replaces the deprecated field instrumentation approach
    class Extension < GraphQL::Schema::FieldExtension
      def resolve(object:, arguments:, context:, **rest)
        # Only apply caching if the field has cache metadata
        cache_config = options[:cache]
        return yield(object, arguments) unless cache_config

        # Create a resolver to handle the caching logic
        resolver = Resolver.new(field.owner, field)
        
        # Store the cache config in the field for the resolver to access
        # In GraphQL 2.x, we store it in the extension options
        field.instance_variable_set(:@cache_config, cache_config)
        
        resolver.call(object, arguments, context) do
          yield(object, arguments)
        end
      end
    end
  end
end 
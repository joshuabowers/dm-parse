module DataMapper
  module Adapters

    class ParseAdapter < AbstractAdapter
      include Parse::Conditions
      include Query::Conditions

      HOST              = "https://api.parse.com"
      VERSION           = "1"
      APP_ID_HEADER     = "X-Parse-Application-Id"
      API_KEY_HEADER    = "X-Parse-REST-API-Key"
      MASTER_KEY_HEADER = "X-Parse-Master-Key"

      attr_reader :classes, :users

      def initialize(name, options)
        super
        @classes  = build_parse_resource_for "classes"
        @users    = build_parse_resource_for "users"
      end

      def parse_resources_for(model)
        model.storage_name == "_User" ? users : classes[model.storage_name]
      end

      def parse_resource_for(resource)
        parse_resources_for(resource.model)[resource.id]
      end

      def create(resources)
        resources.each do |resource|
          params  = attributes_as_fields(resource.attributes(:property)).except("objectId", "createdAt", "updatedAt")
          model   = resource.model
          result  = parse_resources_for(model).post params: params
          initialize_serial resource, result["objectId"]
        end.size
      end

      def read(query)
        model     = query.model
        params    = parse_params_for(query)
        response  = parse_resources_for(model).get params: params
        response["results"]
      end

      def delete(resources)
        resources.each do |resource|
          parse_resource_for(resource).delete
        end.size
      end

      def update(attributes, resources)
        resources.each do |resource|
          params  = attributes_as_fields(attributes).except("createdAt", "updatedAt")
          parse_resource_for(resource).put(params: params)
        end.size
      end

      private
      def build_parse_resource_for(name)
        key_type  = @options[:master] ? MASTER_KEY_HEADER : API_KEY_HEADER
        headers   = {APP_ID_HEADER => @options[:app_id], key_type => @options[:api_key]}
        Parse::Resource.new(HOST, format: :json, headers: headers)[VERSION][name]
      end

      def parse_params_for(query)
        result = { :limit => parse_limit_for(query) }
        if conditions = parse_conditions_for(query)
          result[:where] = conditions.to_json
        end
        if (offset = parse_offset_for(query)) > 0
          result[:skip] = offset
        end
        if orders = parse_orders_for(query)
          result[:order] = orders
        end
        result
      end

      def parse_orders_for(query)
        # cannot use objectId as order field on Parse
        orders = query.order.reject { |order| order.target.field == "objectId" }.map do |order|
          field = order.target.field
          order.operator == :desc ? "-" + field : field
        end.join(",")

        orders.blank? ? nil : orders
      end

      def parse_offset_for(query)
        query.offset
      end

      def parse_limit_for(query)
        limit = query.limit || 1000
        raise "Parse limit: only number from 1 to 1000 is valid" unless (1..1000).include?(limit)
        limit 
      end

      def parse_conditions_for(query)
        conditions  = query.conditions
        return nil if conditions.blank?

        case conditions
        when NotOperation
          parse_query = Parse::Conditions::Query.new
          feed_reversely(parse_query, conditions)
        when AndOperation
          parse_query = Parse::Conditions::Query.new
          feed_directly(parse_query, conditions)
        when OrOperation
          parse_query = Parse::Conditions::Or.new
          feed_or(parse_query, conditions)
        end

        parse_query.build
      end

      def feed_for(parse_query, condition, comparison_class)
        field       = condition.subject.field
        comparison  = comparison_class.new condition.value
        parse_query.add field, comparison
      end

      def feed_reversely(parse_query, conditions)
        conditions.each do |condition|
          case condition
          when EqualToComparison              then feed_for(parse_query, condition, Ne)
          when GreaterThanComparison          then feed_for(parse_query, condition, Lte)
          when GreaterThanOrEqualToComparison then feed_for(parse_query, condition, Lt)
          when LessThanComparison             then feed_for(parse_query, condition, Gte)
          when LessThanOrEqualToComparison    then feed_for(parse_query, condition, Gt)
          when NotOperation                   then feed_directly(parse_query, condition)
          when AndOperation                   then feed_reversely(parse_query, condition)
          when InclusionComparison            then feed_for(parse_query, condition, Nin)
          else
            raise NotImplementedError
          end
        end
      end

      def feed_directly(parse_query, conditions)
        conditions.each do |condition|
          feed_with_condition parse_query, condition
        end
      end

      def feed_or(queries, conditions)
        conditions.each do |condition|
          parse_query = Parse::Conditions::Query.new
          feed_with_condition parse_query, condition
          queries.add parse_query
        end
      end

      def feed_with_condition(parse_query, condition)
        case condition
        when RegexpComparison               then feed_for(parse_query, condition, Regex)
        when EqualToComparison              then feed_for(parse_query, condition, Eql)
        when GreaterThanComparison          then feed_for(parse_query, condition, Gt)
        when GreaterThanOrEqualToComparison then feed_for(parse_query, condition, Gte)
        when LessThanComparison             then feed_for(parse_query, condition, Lt)
        when LessThanOrEqualToComparison    then feed_for(parse_query, condition, Lte)
        when NotOperation                   then feed_reversely(parse_query, condition)
        when AndOperation                   then feed_directly(parse_query, condition)
        when InclusionComparison            then feed_for(parse_query, condition, In)
        else
          raise NotImplementedError
        end
      end

    end

    const_added(:ParseAdapter)
  end
end

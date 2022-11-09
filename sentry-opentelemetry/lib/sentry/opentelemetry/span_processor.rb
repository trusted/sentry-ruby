require 'singleton'

module Sentry
  module OpenTelemetry
    class SpanProcessor < ::OpenTelemetry::SDK::Trace::SpanProcessor
      include Singleton

      SEMANTIC_CONVENTIONS = ::OpenTelemetry::SemanticConventions::Trace

      attr_reader :span_map

      def initialize
        @span_map = {}
      end

      def on_start(otel_span, _parent_context)
        return unless Sentry.initialized? && Sentry.configuration.instrumenter == :otel
        return if from_sentry_sdk?(otel_span)

        span_id, trace_id, parent_span_id = get_trace_data(otel_span)
        return unless span_id

        sentry_parent_span = @span_map[parent_span_id] if parent_span_id

        sentry_span = if sentry_parent_span
          Sentry.configuration.logger.info("Continuing otel span #{otel_span.name} on parent #{sentry_parent_span.op}")

          sentry_parent_span.start_child(
            span_id: span_id,
            description: otel_span.name,
            start_timestamp: otel_span.start_timestamp / 1e9
          )
        else
          Sentry.configuration.logger.info("Starting otel transaction #{otel_span.name}")

          options = {
            instrumenter: :otel,
            name: otel_span.name,
            span_id: span_id,
            trace_id: trace_id,
            parent_span_id: parent_span_id,
            start_timestamp: otel_span.start_timestamp / 1e9
          }

          Sentry.start_transaction(**options)
        end

        @span_map[span_id] = sentry_span
      end

      def on_finish(otel_span)
        return unless Sentry.initialized? && Sentry.configuration.instrumenter == :otel

        span_id = otel_span.context.hex_span_id unless otel_span.context.span_id == ::OpenTelemetry::Trace::INVALID_SPAN_ID
        return unless span_id

        sentry_span = @span_map.delete(span_id)
        return unless sentry_span

        sentry_span.set_op(otel_span.name)

        if sentry_span.is_a?(Sentry::Transaction)
          sentry_span.set_name(otel_span.name)
          sentry_span.set_context(:otel, otel_context_hash(otel_span))
        else
          update_span_with_otel_data(sentry_span, otel_span)
        end

        Sentry.configuration.logger.info("Finishing sentry_span #{sentry_span.op}")
        sentry_span.finish(end_timestamp: otel_span.end_timestamp / 1e9)
      end

      private

      def from_sentry_sdk?(otel_span)
        dsn = Sentry.configuration.dsn
        return false unless dsn

        if otel_span.name.start_with?("HTTP")
          # only check client requests, connects are sometimes internal
          return false unless %i(client internal).include?(otel_span.kind)

          address = otel_span.attributes[SEMANTIC_CONVENTIONS::NET_PEER_NAME]

          # if no address drop it, just noise
          return true unless address
          return true if dsn.host == address
        end

        false
      end

      # TODO-neel get sentry-trace/baggage from context
      def get_trace_data(otel_span)
        if otel_span.context.valid?
          span_id = otel_span.context.hex_span_id
          trace_id = otel_span.context.hex_trace_id
        else
          span_id = nil
          trace_id = nil
        end

        parent_span_id = otel_span.parent_span_id.unpack1("H*") unless otel_span.parent_span_id == ::OpenTelemetry::Trace::INVALID_SPAN_ID

        [span_id, trace_id, parent_span_id]
      end

      def otel_context_hash(otel_span)
        otel_context = {}
        otel_context[:attributes] = otel_span.attributes unless otel_span.attributes.empty?

        resource_attributes = otel_span.resource.attribute_enumerator.to_h
        otel_context[:resource] = resource_attributes unless resource_attributes.empty?

        otel_context
      end

      def update_span_with_otel_data(sentry_span, otel_span)
        otel_span.attributes&.each { |k, v| sentry_span.set_data(k, v) }

        op = otel_span.name
        description = otel_span.name

        if (http_method = otel_span.attributes[SEMANTIC_CONVENTIONS::HTTP_METHOD])
          op = "http.#{otel_span.kind}"
          description = http_method

          peer_name = otel_span.attributes[SEMANTIC_CONVENTIONS::NET_PEER_NAME]
          description += " #{peer_name}" if peer_name

          target = otel_span.attributes[SEMANTIC_CONVENTIONS::HTTP_TARGET]
          description += target if target

          status_code = otel_span.attributes[SEMANTIC_CONVENTIONS::HTTP_STATUS_CODE]
          sentry_span.set_http_status(status_code) if status_code
        elsif otel_span.attributes[SEMANTIC_CONVENTIONS::DB_SYSTEM]
          op = "db"

          statement = otel_span.attributes[SEMANTIC_CONVENTIONS::DB_STATEMENT]
          description = statement if statement
        end

        sentry_span.set_op(op)
        sentry_span.set_description(description)
      end
    end
  end
end

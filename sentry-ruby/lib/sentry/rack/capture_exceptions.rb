module Sentry
  module Rack
    class CaptureExceptions
      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless Sentry.initialized?

        # make sure the current thread has a clean hub
        Sentry.clone_hub_to_current_thread

        Sentry.with_scope do |scope|
          scope.clear_breadcrumbs
          scope.set_transaction_name(env["PATH_INFO"]) if env["PATH_INFO"]
          scope.set_rack_env(env)

          transaction = start_transaction(env, scope)
          scope.set_span(transaction) if transaction

          begin
            response = nil

            if Sentry.configuration.capture_exception_frame_locals
              exception_locals_tp.enable do
                response = @app.call(env)
              end
            else
              response = @app.call(env)
            end
          rescue Sentry::Error
            finish_transaction(transaction, 500)
            raise # Don't capture Sentry errors
          rescue Exception => e
            capture_exception(e)
            finish_transaction(transaction, 500)
            raise
          end

          exception = collect_exception(env)
          capture_exception(exception) if exception

          finish_transaction(transaction, response[0])

          response
        end
      end

      private

      def exception_locals_tp
        TracePoint.new(:raise) do |tp|
          exception = tp.raised_exception

          # don't collect locals again if the exception is re-raised
          next if exception.instance_variable_get(:@sentry_locals)

          locals = tp.binding.local_variables.each_with_object({}) do |local, result|
            result[local] = tp.binding.local_variable_get(local)
          end

          exception.instance_variable_set(:@sentry_locals, locals)
        end
      end

      def collect_exception(env)
        env['rack.exception'] || env['sinatra.error']
      end

      def transaction_op
        "rack.request".freeze
      end

      def capture_exception(exception)
        Sentry.capture_exception(exception)
      end

      def start_transaction(env, scope)
        sentry_trace = env["HTTP_SENTRY_TRACE"]
        options = { name: scope.transaction_name, op: transaction_op }
        transaction = Sentry::Transaction.from_sentry_trace(sentry_trace, **options) if sentry_trace
        Sentry.start_transaction(transaction: transaction, **options)
      end


      def finish_transaction(transaction, status_code)
        return unless transaction

        transaction.set_http_status(status_code)
        transaction.finish
      end
    end
  end
end

#--
# DO NOT MODIFY!!!!
# This file is automatically generated by rex 1.0.7
# from lexical definition file "lexer.rex".
#++

require 'racc/parser'
class ReplanParser < Racc::Parser
      require 'strscan'

      class ScanError < StandardError ; end

      attr_reader   :lineno
      attr_reader   :filename
      attr_accessor :state

      def scan_setup(str)
        @ss = StringScanner.new(str)
        @lineno =  1
        @state  = nil
      end

      def action
        yield
      end

      def scan_str(str)
        scan_setup(str)
        do_parse
      end
      alias :scan :scan_str

      def load_file( filename )
        @filename = filename
        File.open(filename, "r") do |f|
          scan_setup(f.read)
        end
      end

      def scan_file( filename )
        load_file(filename)
        do_parse
      end


        def next_token
          return if @ss.eos?

          # skips empty actions
          until token = _next_token or @ss.eos?; end
          token
        end

        def _next_token
          text = @ss.peek(1)
          @lineno  +=  1  if text == "\n"
          token = case @state
            when nil
          case
                  when (text = @ss.scan(/replan/))
                     action { [:REPLAN, text] }

                  when (text = @ss.scan(/\s+/))
                     action { [:WHITESPACE, text] }

                  when (text = @ss.scan(/mon|tue|wed|thu|fri|sat|sun/))
                     action { [:DAY, text] }

                  when (text = @ss.scan(/f/))
                     action { [:F, text] }

                  when (text = @ss.scan(/s/))
                     action { [:S, text] }

                  when (text = @ss.scan(/u/))
                     action { [:U, text] }

                  when (text = @ss.scan(/\d{1,2}:\d\d/))
                     action { [:TIME, text] }

                  when (text = @ss.scan(/\d+(\.\d+)?[dwmy]?/))
                     action { [:INTERVAL, text] }

                  when (text = @ss.scan(/in/))
                     action { [:IN, text] }

          
          else
            text = @ss.string[@ss.pos .. -1]
            raise  ScanError, "can not match: '" + text + "'"
          end  # if

        else
          raise  ScanError, "undefined state: '" + state.to_s + "'"
        end  # case state
          token
        end  # def _next_token

end # class
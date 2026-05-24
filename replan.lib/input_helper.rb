require 'reline'

class InputHelper
  def ask(message, prefill: "")
    puts message

    leading_ws = prefill[/\A\s*/]
    prefill_body = prefill[leading_ws.length..]

    if prefill_body != ""
      Reline.pre_input_hook = -> {
        Reline.insert_text(prefill_body)
        Reline.redisplay
      }
    end

    leading_ws + Reline.readline("", true).sub(/\A\s*/, '')
  ensure
    Reline.pre_input_hook = nil
  end
end

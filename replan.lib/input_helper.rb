require 'reline'

class InputHelper
  def ask(message, prefill: "")
    puts message

    if prefill != ""
      Reline.pre_input_hook = -> {
        Reline.insert_text(prefill)
        Reline.redisplay
      }
    end

    Reline.readline("", true)
  ensure
    Reline.pre_input_hook = nil
  end
end

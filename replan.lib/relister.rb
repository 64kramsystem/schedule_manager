require_relative 'adjusted_date_wday'
require_relative 'relister'
require_relative 'replan_codec'
require_relative 'replan_helper'

require 'date'
require 'English'
require 'stringio'
require 'json'

class TextFormatter
  def initialize(**)
    @buffer = StringIO.new
  end

  def add_delimiter
    @buffer.puts "====="
    @buffer.puts
  end

  def start_date(date)
    @buffer.puts(date)
  end

  def add_event(title)
    @buffer.puts(title)
  end

  def end_date
    @buffer.puts
  end

  def finalize
    @buffer.string
  end
end

# Format:
#
# [
#   {"date": "<YYYY-mm-dd>", "title": "<title>"},
#   ...
# ]
#
class JsonFormatter
  EXPECTED_DATE_FORMAT = %r{^ +[A-Z]{3} (\d{2}/[A-Z]{3}/\d{4})\n$}
  EXPECTED_TITLE_FORMAT = ->(event_symbols) { /^([#{event_symbols}]) (.+)\n/ }

  def initialize(event_symbols:)
    @data = []
    @current_date = nil
    @event_symbols = event_symbols
  end

  def add_delimiter
    # do nothing!
  end

  def start_date(raw_date)
    raise "Invalid date: #{raw_date.inspect}" if raw_date !~ EXPECTED_DATE_FORMAT
    @current_date = Date.parse($LAST_MATCH_INFO[1])
  end

  def add_event(raw_title)
    raise "Invalid title: #{raw_title.inspect}" if raw_title !~ EXPECTED_TITLE_FORMAT[@event_symbols]
    @data << {date: @current_date.strftime("%F"), title: $LAST_MATCH_INFO[2], type: $LAST_MATCH_INFO[1]}
  end

  def end_date
    @current_date = nil
  end

  def finalize
    JSON.pretty_generate(@data)
  end
end

# Simple listing of the main events
#
class Relister
  include ReplanHelper
  using AdjustedDateWday

  DEFAULT_DAYS_LISTED = 21

  # The terminal space is used to disambiguate headers from event symbols using a letter.
  #
  EVENTS_REGEX = ->(event_symbols) { /^\s*[#{event_symbols}] / }
  INTERVAL_START_REGULAR = -> { Date.today + 1 }

  def initialize(event_symbols)
    @replan_codec = ReplanCodec.new
    @event_symbols = event_symbols
  end

  # params:
  #   :export: Date to start the export from (inclusive)
  #
  def execute(content, export: nil)
    interval_start = export || INTERVAL_START_REGULAR[]

    formatter_class, interval_end = if export
      [JsonFormatter, find_last_date(content)]
    else
      [TextFormatter, interval_start + DEFAULT_DAYS_LISTED - 1]
    end

    formatter = formatter_class.new(event_symbols: @event_symbols)

    (interval_start..interval_end).inject(nil) do |previous_date, date|
      if previous_date && date.adjusted_wday < previous_date.adjusted_wday
        formatter.add_delimiter
      end

      section = find_date_section(content, date, allow_not_found: true)

      next if section.nil?

      header = section.lines.first
      events = section.lines.grep(EVENTS_REGEX[@event_symbols])

      if events.empty?
        previous_date
      else
        formatter.start_date(header)

        events.each do |event|
          event = event.lstrip

          if !replan_line?(event)
            event = remove_notes(event)
            formatter.add_event(event)
          elsif !skipped_event?(event)
            event = strip_replan(event)
            event = remove_notes(event)
            formatter.add_event(event)
          end
        end

        formatter.end_date

        date
      end
    end

    output = formatter.finalize

    print output
  end

  private

  def replan_line?(line)
    @replan_codec.replan_line?(line)
  end

  def skipped_event?(line)
    @replan_codec.skipped_event?(line)
  end

  def strip_replan(line)
    line.sub(/ \(replan.*\)$/, '')
  end

  def remove_notes(line)
    line.gsub(/ \[.+?\]/, '')
  end
end # class Relister

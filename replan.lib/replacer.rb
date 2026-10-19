require_relative 'replan_helper'

class Replacer
  include ReplanHelper

  DIRECTIVE_PATTERN = /
    \{\{replace[\t ]+
    (?:
      '(?<single>(?:\\.|[^'\\\n])*)'
      | "(?<double>(?:\\.|[^"\\\n])*)"
      | \/(?<regex>(?:\\.|[^\/\\\n])*)\/
    )
    [\t ]*\}\}[\t ]*
  /x
  private_constant :DIRECTIVE_PATTERN

  def execute(content, dates: find_all_dates(content))
    return content unless content.include?('{{replace')

    dates.each do |date|
      section = find_date_section(content, date)
      next unless section.include?('{{replace')

      content = content.sub(section) { replace_lines(section, date) }
    end

    content
  end

  private

  def replace_lines(section, date)
    lines = section.lines
    directives = {}

    lines.each_with_index do |line, line_i|
      next unless line.include?('{{replace')

      directive = line.match(DIRECTIVE_PATTERN)
      if !directive || line.sub(DIRECTIVE_PATTERN, '').include?('{{replace')
        raise "Invalid replace directive on #{date}: #{line.strip.inspect}"
      end

      directives[line_i] = directive
    end

    directives.each do |line_i, directive|
      matcher = matcher_for(directive)
      matches = lines.each_with_index.select do |line, candidate_i|
        next false if candidate_i.zero? || directives.key?(candidate_i) || line.strip.empty?
        next false if line == TIME_BRACKETS_SEPARATOR ||
          line.match?(TODO_SECTION_SEPARATOR_REGEX) || line.match?(/\A[~=]\n\z/)

        matcher.match?(line.chomp)
      end
      if matches.size != 1
        raise "Replace on #{date} requires exactly one matching line; found #{matches.size}: #{directive[0].strip}"
      end

      target_i = matches.first.last
      lines[target_i] = lines[line_i].sub(DIRECTIVE_PATTERN, '').rstrip + "\n"
      lines[line_i] = ''
    end

    lines.join
  end

  def matcher_for(directive)
    return Regexp.new(directive[:regex]) if directive[:regex]

    quote = directive[:single] ? "'" : '"'
    text = (directive[:single] || directive[:double]).gsub(/\\(.)/) do |escaped|
      [quote, '\\'].include?(escaped[1]) ? escaped[1] : escaped
    end

    Regexp.new(Regexp.escape(text))
  end
end

require 'English'

require_relative 'replan_codec'

# Copy children from template files into matching schedule placeholders.
#
class Resnapper
  SNAP_REFERENCE_REGEX = /\{\{@(.+?)\}\}/

  def initialize(templates_directory)
    @templates_directory = templates_directory
    @replan_codec = ReplanCodec.new
  end

  def self.snap_reference?(content)
    content.match?(SNAP_REFERENCE_REGEX)
  end

  def execute(content)
    lines = content.lines(chomp: true)
    keep_final_newline = content.end_with?("\n")

    edited_lines = lines.each_with_index.flat_map do |line, i|
      next [line] if line !~ SNAP_REFERENCE_REGEX

      reference = $LAST_MATCH_INFO[1]
      next [line] if no_current_occurrence?(line)

      if next_line_has_children?(line, lines[i + 1])
        [line]
      else
        [line] + indented_children(reference, line)
      end
    end

    edited_content = edited_lines.join("\n")
    edited_content += "\n" if keep_final_newline
    edited_content
  end

  private

  def strip_blank_lines(lines)
    lines = lines.dup

    lines.shift while lines.first&.strip == ''
    lines.pop while lines.last&.strip == ''

    lines
  end

  def next_line_has_children?(line, next_line)
    next_line && indentation_size(next_line) > indentation_size(line)
  end

  # Skip/once replans don't represent an occurrence on the current date. Leave their snap references
  # unresolved so Replanner can move the reference without seeing generated children on that date.
  #
  def no_current_occurrence?(line)
    return false unless @replan_codec.replan_line?(line)

    replan_data = @replan_codec.extract_replan_tokens(line, allow_placeholder: true)
    replan_data.skip || replan_data.once
  end

  def indented_children(reference, line)
    raise "Invalid template reference: #{reference}" if reference.include?('/') || reference == '.' || reference == '..'

    filename = File.join(@templates_directory, "#{reference}.txt")
    raise "Template file not found: #{filename}" unless File.file?(filename)

    children = strip_blank_lines(IO.readlines(filename, chomp: true))
    child_indentation = indentation(line) + '  '

    children.map do |child|
      child.empty? ? child : child_indentation + child
    end
  end

  def indentation(line)
    line[/^ */]
  end

  def indentation_size(line)
    indentation(line).size
  end
end

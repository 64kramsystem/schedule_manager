require_relative 'replan_codec'

# Expand references to template files in the schedule.
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
    edited_lines = expand_references(content.lines(chomp: true))
    edited_content = edited_lines.join("\n")
    edited_content += "\n" if content.end_with?("\n") && !edited_lines.empty?
    edited_content
  end

  private

  def expand_references(lines)
    expanded = []
    line_i = 0

    while line_i < lines.size
      line = lines[line_i]
      line_i += 1
      reference = line[SNAP_REFERENCE_REGEX, 1]

      # Replanner needs the original reference to schedule the next occurrence.
      if !reference || @replan_codec.replan_line?(line)
        expanded << line
        next
      end

      child_start = line_i
      line_i += 1 while child_line?(line, lines[line_i])
      children = expand_references(lines[child_start...line_i])
      parent_indentation = indentation(line)
      name = reference.delete_suffix('-')

      if reference.end_with?('-')
        expanded.concat(promote_children(children, parent_indentation))
        expanded.concat(indented_children(name, parent_indentation))
      else
        expanded << line.sub(SNAP_REFERENCE_REGEX) { name }
        expanded.concat(children)
        expanded.concat(indented_children(name, parent_indentation + '  '))
      end
    end

    expanded
  end

  def promote_children(children, parent_indentation)
    child_indent = children.reject { |line| line.strip.empty? }.map { |line| indentation_size(line) }.min
    children.map { |line| line.strip.empty? ? line : parent_indentation + line[child_indent..] }
  end

  def strip_blank_lines(lines)
    lines = lines.dup

    lines.shift while lines.first&.strip == ''
    lines.pop while lines.last&.strip == ''

    lines
  end

  def child_line?(parent, line)
    line && indentation_size(line) > indentation_size(parent)
  end

  def indented_children(reference, child_indentation)
    raise "Invalid template reference: #{reference}" if reference.empty? || reference.include?('/') || reference == '.' || reference == '..'

    filename = File.join(@templates_directory, "#{reference}.txt")
    raise "Template file not found: #{filename}" unless File.file?(filename)

    children = strip_blank_lines(IO.readlines(filename, chomp: true))

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

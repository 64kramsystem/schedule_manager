class Cleaner
  TEMPORARY_SEPARATOR_PATTERN = /^[~=]\n/

  def execute(content)
    content.gsub(TEMPORARY_SEPARATOR_PATTERN, '')
  end
end

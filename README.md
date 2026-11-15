# Schedule manager

This is my schedule manager, which automates the most important tasks on my schedule file (a flat text file).

It's of no particular interest to the general public, but my philosophy is to open my code as much as possible.

There is a reasonable test suite, which also describes the format (since I'm the only user, there is no formal documentation).

References such as `{{@weekly_dos}}` insert the contents of `weekly_dos.txt` as children. The file is read from the directory containing the configured `template_filename`, including when `--no-template` is used. Existing children are left unchanged.

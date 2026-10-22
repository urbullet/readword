# frozen_string_literal: true

require_relative 'lib/readword/version'

Gem::Specification.new do |spec|
  spec.name = 'readword'
  spec.version = Readword::VERSION
  spec.authors = ['urbullet']
  spec.summary = 'Turn Word .doc and .docx files into Markdown, in plain Ruby.'
  spec.description = 'Reads Word 97-2003 (.doc) and Word 2007+ (.docx) files without LibreOffice, Java or antiword, ' \
                     'and prints their text, tables, headers, footers and footnotes as Markdown. ' \
                     'Built for feeding Word documents to LLMs and coding agents, and safe on untrusted files.'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.files = Dir['lib/**/*.rb', 'exe/*', 'README.md', 'LICENSE.txt', 'CHANGELOG.md']
  spec.bindir = 'exe'
  spec.executables = ['readword']

  spec.add_dependency 'nokogiri', '>= 1.13'
  spec.add_dependency 'rubyzip', '>= 2.3', '< 4'

  spec.metadata['rubygems_mfa_required'] = 'true'
end

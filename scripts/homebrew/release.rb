# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "uri"

module HomebrewRelease
  def self.render_formula(template, version, url, sha256)
    raise "Invalid version" unless version.match?(/\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\z/)
    raise "Invalid source URL" unless URI(url).is_a?(URI::HTTPS)
    raise "Invalid source checksum" unless sha256.match?(/\A[0-9a-f]{64}\z/)

    { "url" => url, "version" => version, "sha256" => sha256 }.each do |key, value|
      pattern = /^  #{key} ".*"$/
      raise "Expected one #{key} placeholder" unless template.scan(pattern).length == 1

      template = template.sub(pattern) { "  #{key} #{value.dump}" }
    end
    template
  end

  # Homebrew's local bottle name contains '--'; its download name contains
  # '-'. Publish the name from its JSON, after checking the actual payload.
  def self.stage_bottles(input, output, version, root_url, expected_count)
    formulae = Dir.glob(File.join(input, "**", "vch.rb"))
    json_files = Dir.glob(File.join(input, "**", "*.bottle.json"))
    raise "Incomplete bottle matrix" unless formulae.length == expected_count && json_files.length == expected_count

    templates = formulae.map { |path| File.read(path) }.uniq
    raise "Bottle builds used different formulae" unless templates.length == 1

    tags = []
    payloads = json_files.map do |json_path|
      json = JSON.parse(File.read(json_path))
      raise "Unexpected formula" unless json.keys == ["maples7/tap/vch"]

      metadata = json.fetch("maples7/tap/vch")
      raise "Version mismatch" unless metadata.fetch("formula").fetch("pkg_version") == version

      bottle = metadata.fetch("bottle")
      raise "Root URL mismatch" unless bottle.fetch("root_url") == root_url
      raise "Expected one platform per bottle" unless bottle.fetch("tags").length == 1

      tag, payload = bottle.fetch("tags").first
      raise "Duplicate or architecture-independent bottle" if tag == "all" || tags.include?(tag)

      tags << tag
      cellar = payload["cellar"] || bottle.fetch("cellar")
      raise "Bottle is not relocatable: #{tag}" unless %w[any any_skip_relocation].include?(cellar)

      names = payload.values_at("local_filename", "filename")
      unless names.all? { |name| name.is_a?(String) && name.match?(/\Avch-[A-Za-z0-9_.-]+\.bottle\.tar\.gz\z/) }
        raise "Invalid bottle filename"
      end
      source = File.join(File.dirname(json_path), names.first)
      raise "Bottle checksum mismatch: #{tag}" unless Digest::SHA256.file(source).hexdigest == payload.fetch("sha256")

      [source, names.last, json_path]
    end

    FileUtils.mkdir_p(output)
    File.write(File.join(output, "vch.rb"), templates.first)
    payloads.each do |source, filename, json_path|
      FileUtils.cp(source, File.join(output, filename))
      FileUtils.cp(json_path, File.join(output, File.basename(json_path)))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV.shift
  when "render"
    template, destination, version, url, sha256 = ARGV
    File.write(destination, HomebrewRelease.render_formula(File.read(template), version, url, sha256))
  when "stage"
    input, output, version, root_url, count = ARGV
    HomebrewRelease.stage_bottles(input, output, version, root_url, Integer(count))
  else
    abort "Usage: release.rb render TEMPLATE DEST VERSION URL SHA256 | stage INPUT OUTPUT VERSION ROOT_URL COUNT"
  end
end

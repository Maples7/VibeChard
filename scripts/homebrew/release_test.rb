# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "release"

class HomebrewReleaseTest < Minitest::Test
  VERSION = "1.2.3"
  ROOT_URL = "https://github.com/Maples7/VibeChard/releases/download/v#{VERSION}"

  def test_render_preserves_formula_and_sets_release_source
    template = File.read(File.expand_path("../../Formula/vch.rb", __dir__))
    rendered = HomebrewRelease.render_formula(template, VERSION, "https://example.com/source.tar.gz", "a" * 64)
    assert_includes rendered, '  version "1.2.3"'
    assert_includes rendered, '  url "https://example.com/source.tar.gz"'
    assert_includes rendered, 'libexec.install ".build/release/vch-xcodebuild-shim"'
    assert_includes rendered, "depends_on macos: :ventura"
    refute_includes rendered, "depends_on :macos"
  end

  def test_render_refuses_missing_or_duplicate_placeholders
    ["", "  url \"a\"\n  url \"b\"\n"].each do |template|
      assert_raises(RuntimeError) do
        HomebrewRelease.render_formula(template, VERSION, "https://example.com/source", "a" * 64)
      end
    end
  end

  def fixture(directory, tag)
    build = File.join(directory, tag)
    FileUtils.mkdir_p(build)
    local = "vch--#{VERSION}.#{tag}.bottle.tar.gz"
    remote = "vch-#{VERSION}.#{tag}.bottle.tar.gz"
    File.write(File.join(build, local), "fixture for #{tag}")
    File.write(File.join(build, "vch.rb"), "release formula")
    metadata = {
      "maples7/tap/vch" => {
        "formula" => { "pkg_version" => VERSION },
        "bottle" => {
          "root_url" => ROOT_URL, "cellar" => "any_skip_relocation",
          "tags" => { tag => {
            "local_filename" => local, "filename" => remote,
            "sha256" => Digest::SHA256.file(File.join(build, local)).hexdigest,
          } },
        },
      },
    }
    path = File.join(build, "vch--#{VERSION}.#{tag}.bottle.json")
    File.write(path, JSON.generate(metadata))
    [path, metadata, remote]
  end

  def test_stage_uses_download_names_and_checks_all_platforms
    Dir.mktmpdir do |dir|
      input = File.join(dir, "input")
      _, _, arm = fixture(input, "arm64_sonoma")
      _, _, intel = fixture(input, "sequoia")
      output = File.join(dir, "output")
      HomebrewRelease.stage_bottles(input, output, VERSION, ROOT_URL, 2)
      assert_equal "fixture for arm64_sonoma", File.read(File.join(output, arm))
      assert_equal "fixture for sequoia", File.read(File.join(output, intel))
      assert_equal 2, Dir.glob(File.join(output, "*.bottle.json")).length
    end
  end

  def test_stage_rejects_missing_platforms_and_corrupted_payloads
    Dir.mktmpdir do |dir|
      input = File.join(dir, "input")
      path, data, = fixture(input, "arm64_sonoma")
      output = File.join(dir, "output")
      assert_raises(RuntimeError) { HomebrewRelease.stage_bottles(input, output, VERSION, ROOT_URL, 2) }
      data["maples7/tap/vch"]["bottle"]["tags"]["arm64_sonoma"]["sha256"] = "0" * 64
      File.write(path, JSON.generate(data))
      assert_raises(RuntimeError) { HomebrewRelease.stage_bottles(input, output, VERSION, ROOT_URL, 1) }
      refute File.exist?(output)
    end
  end

  def test_stage_rejects_other_versions_urls_and_unsafe_filenames
    Dir.mktmpdir do |dir|
      input = File.join(dir, "input")
      path, data, = fixture(input, "arm64_sonoma")
      output = File.join(dir, "output")
      assert_raises(RuntimeError) { HomebrewRelease.stage_bottles(input, output, "9.9.9", ROOT_URL, 1) }
      assert_raises(RuntimeError) { HomebrewRelease.stage_bottles(input, output, VERSION, "https://wrong.example", 1) }
      data["maples7/tap/vch"]["bottle"]["tags"]["arm64_sonoma"]["filename"] = "../outside.bottle.tar.gz"
      File.write(path, JSON.generate(data))
      assert_raises(RuntimeError) { HomebrewRelease.stage_bottles(input, output, VERSION, ROOT_URL, 1) }
      refute File.exist?(output)
    end
  end
end

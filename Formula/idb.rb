# Homebrew formula TEMPLATE for the NB idb build.
#
# release/release.sh renders this into a concrete `idb.rb` by substituting the
# @@PLACEHOLDERS@@ with the version, the GitHub-release asset URLs, and their
# computed sha256s. The rendered file is byte-identical for both distribution
# modes — only WHERE it lands differs (tap repo vs Formula/idb.rb in this fork).
#
# Placeholders: 1.1.8-nb-b891d6a69 https://github.com/Ginger-Labs/idb/releases/download/v1.1.8-nb-b891d6a69/idb_companion-1.1.8-nb-b891d6a69-arm64.tar.gz ad852480637768a274f4b53609b9ea251fd9eefd25fd866ffe53588230ae1246
#               https://github.com/Ginger-Labs/idb/releases/download/v1.1.8-nb-b891d6a69/fb_idb-1.1.8+nb.b891d6a69-py3-none-any.whl b9fc2ae3c3b9b016a0b9cc8fff06cead5214c7c694a02d1734f5278f04ba9623
#
# One formula installs BOTH halves so the client and companion can never drift
# out of lockstep (they share the pinned proto).
class Idb < Formula
  include Language::Python::Virtualenv

  desc "Notability build of the iOS Debug Bridge client and companion"
  homepage "https://github.com/Ginger-Labs/idb"
  # Primary download: the self-contained macOS companion bundle (idb_companion +
  # idb-repl + shim dylibs + SimulatorFrameworkBridge). Currently arm64-only;
  # rebuild universal and re-render to widen support.
  url "https://github.com/Ginger-Labs/idb/releases/download/v1.1.8-nb-b891d6a69/idb_companion-1.1.8-nb-b891d6a69-arm64.tar.gz"
  version "1.1.8-nb-b891d6a69"
  sha256 "ad852480637768a274f4b53609b9ea251fd9eefd25fd866ffe53588230ae1246"
  license "MIT"

  depends_on :macos # companion links Apple's private CoreSimulator frameworks
  depends_on "python@3.12" # client uses asyncio.get_event_loop(), gone in 3.13+

  # Upstream's facebook/fb/idb-companion installs a binary of the same name.
  conflicts_with "idb-companion", because: "both install an idb_companion binary"

  # The pure-Python client wheel, built from the same pinned proto as the companion.
  resource "fb-idb" do
    url "https://github.com/Ginger-Labs/idb/releases/download/v1.1.8-nb-b891d6a69/fb_idb-1.1.8+nb.b891d6a69-py3-none-any.whl"
    sha256 "b9fc2ae3c3b9b016a0b9cc8fff06cead5214c7c694a02d1734f5278f04ba9623"
  end

  def install
    # 1) Companion bundle -> libexec; expose idb_companion on PATH via a symlink.
    #    The bundle is relocatable: its rpaths are @executable_path-relative, and
    #    @executable_path (and Bundle.main) resolve through the bin symlink to the
    #    real libexec location, so the sibling Resources/ and *.bundle are found.
    libexec.install Dir["*"]
    bin.install_symlink libexec/"idb_companion"

    # 2) Python client -> its own virtualenv inside libexec; expose `idb` on PATH.
    #    Install the verified wheel file directly (no staging/unzip), letting pip
    #    resolve its deps. cached_download is the sha256-checked file Homebrew
    #    already fetched for the resource above.
    venv_dir = libexec/"venv"
    virtualenv_create(venv_dir, "python3.12")
    system venv_dir/"bin/pip", "install", "--no-cache-dir", resource("fb-idb").cached_download
    bin.install_symlink venv_dir/"bin/idb"
  end

  test do
    # Companion reports the NB version (returns before touching CoreSimulator).
    assert_match "1.1.8-nb-b891d6a69", shell_output("#{bin}/idb_companion --version")
    # Client imports and its CLI parses (the new pinch command is present).
    system bin/"idb", "ui", "pinch", "--help"
  end
end

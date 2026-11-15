#!/bin/sh
# Prints the Homebrew cask for a release, for the uifi95/homebrew-tap repo
# (Casks/listen-together.rb). Run after ./build.sh <version>.
# Usage: packaging/cask.sh <version> [url-base]
#   url-base defaults to the GitHub release download URL, written with
#   #{version} so the cask needs only its version and sha256 bumped.
set -eu

VERSION="$1"
cd "$(dirname "$0")/.."
RELEASES='https://github.com/uifi95/listen-together/releases/download/v#{version}'
BASE="${2:-$RELEASES}"
SHA="$(shasum -a 256 "dist/ListenTogether-$VERSION-macos.zip" | cut -d' ' -f1)"

cat <<RUBY
cask "listen-together" do
  version "$VERSION"
  sha256 "$SHA"

  url "$BASE/ListenTogether-#{version}-macos.zip"
  name "ListenTogether"
  desc "Listen to the same song at the same time across Qobuz and Apple Music"
  homepage "https://github.com/uifi95/listen-together"

  depends_on macos: ">= :sonoma"
  # Creating a room opens a Cloudflare quick tunnel.
  depends_on formula: "cloudflared"

  app "ListenTogether.app"

  # The app is signed ad hoc, not notarized: without this, Gatekeeper blocks
  # the downloaded copy until it's allowed in System Settings.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ListenTogether.app"]
  end

  zap trash: [
    "~/Library/Preferences/app.listentogether.mac.plist",
  ]
end
RUBY

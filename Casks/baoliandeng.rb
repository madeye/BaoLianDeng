cask "baoliandeng" do
  deprecate! date: "2026-04-07", because: "it has been added to the official Homebrew cask repository (https://github.com/Homebrew/homebrew-cask/pull/257930)"

  version "4.0"
  sha256 "31f960d09cb1d6e33f217dbdab988ad3e1590f3cb79b3697f4a7d7b2a28ed543"

  url "https://github.com/madeye/BaoLianDeng/releases/download/v#{version}/BaoLianDeng-#{version}.dmg"
  name "BaoLianDeng"
  desc "macOS VPN proxy app powered by Mihomo (Clash Meta)"
  homepage "https://github.com/madeye/BaoLianDeng"

  depends_on macos: ">= :sonoma"

  app "BaoLianDeng.app"

  postflight do
    system "open", "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
  end

  zap trash: [
    "~/Library/Application Support/mihomo",
    "~/Library/Preferences/io.github.baoliandeng.macos.plist",
  ]
end

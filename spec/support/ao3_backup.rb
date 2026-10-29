module MagicImportFixtures
  def captured(name = "2_unknown", html: nil)
    Ao3Backup::CapturedPage.build(identity: Ao3Backup::SourceIdentity.parse("https://archiveofourown.org/works/12345"),
                                  html: html || File.read(Rails.root.join("spec/fixtures/ao3_backup/#{name}.html")),
                                  retrieved_at: Time.utc(2026, 10, 28))
  end
end

-- Records what a stored report actually covered.
--
-- `DepReport` has always carried these two: `manifests`, the pubspec
-- directories the scan read, and `coverage_note`, set when the scan knowingly
-- reached less than the whole repository. Until this migration `dep_reports`
-- held neither, so a note saying "read 20 of 34 pubspecs" survived in memory
-- and was dropped the moment the report was persisted — the one deployment
-- where the omission matters. See "What a scan covers" in the README.
--
-- Rows written before this migration read back as no manifests and no note,
-- which is what an older single-package report meant anyway.

alter table dep_reports
  add column if not exists manifests     jsonb not null default '[]'::jsonb,
  add column if not exists coverage_note text;

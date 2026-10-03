### Fixed

- **Class resolution no longer counts names that appear only in stylesheet comments.** Its single-line comment strip kept every line of a multi-line comment but the first, so 19 class names that appear only in prose counted as defined, among them the retired `admin-section`, and a template using one passed. The five style guards now share one multi-line stripper and one page `<style>` extractor in `scripts/lib/css.sh`, and a filter in `check-ui-vocabulary.sh` that matched nothing is gone. A new guard fixture proves the defect is caught (#1982).

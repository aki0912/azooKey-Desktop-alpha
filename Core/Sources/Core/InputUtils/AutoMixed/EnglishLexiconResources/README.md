# SCOWL runtime English lexicon (modified subset)

Source: [SCOWL 2020.12.07](https://sourceforge.net/projects/wordlist/files/SCOWL/2020.12.07/), corresponding to upstream revision `5ef55f9c42730ebe4394a78b77855468a6f15dd2`.

The collective work is Copyright 2000–2018 Kevin Atkinson, with the additional notices in the unmodified [Copyright](Copyright) file. That file includes the permission and attribution requirements of the component sources and is shipped with this derived data. No endorsement by the upstream authors is implied.

This is a modified subset, not an upstream spell-checking dictionary. It combines `english`, `american`, `british`, and `british_z` word/contraction lists at levels 10, 20, and 35, keeps exact lowercase ASCII spellings up to 32 characters (including internal apostrophes), deduplicates using the smallest level, and sorts by ASCII spelling. The SCOWL extraction omits names, uppercase lists, abbreviations, accents, other variants and larger levels; the authored additions below supplement that subset. A level indicates source-list commonness, not an observed word frequency or a calibrated probability.

`english.tsv` contains 50,994 entries: 50,957 SCOWL entries plus 37 user-confirmed, authored additions for Apple products, AI, and development. The additions are listed in `provenance.json` and the builder; they use runtime level 20 so the existing common-word and prefix rules apply. This assigned level is a display-policy choice, not a SCOWL frequency classification. Lookup folds ASCII case, while displayed input retains its original spelling. `provenance.json` records the archive and per-file checksums. This data is used only for local runtime lookup; it is not added to train/dev/calibration/test or used for model fitting. No user input is sent to the dictionary source, a spelling service, or a network API.

Reproduce from the official archive (network access is needed only for the download):

```sh
curl --fail --location https://downloads.sourceforge.net/project/wordlist/SCOWL/2020.12.07/scowl-2020.12.07.tar.gz -o build/auto-mixed/scowl-2020.12.07.tar.gz
python3 Tools/build_auto_mixed_english_lexicon.py build/auto-mixed/scowl-2020.12.07.tar.gz --check
```

The builder verifies the pinned SHA-256 before reading selected archive members and refuses to overwrite different generated output. `english-policy.json` is a separate, authored experimental display policy, not SCOWL data or a trained/calibrated model. Its thresholds require broader evaluation before release.

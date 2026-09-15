/// The version the plugin reports.
///
/// A tag is the release in this repository, so the tag is the source of truth and this file
/// is stamped from it at build time by `make stamp`. The value committed here is the
/// placeholder a working copy builds with, so `swift build` on its own still works and says
/// honestly that it is not a release.
///
/// `make build` stamps, builds and puts this back, so a release build never leaves the tree
/// dirty. Nothing should edit this by hand: a hand-edited version is one that can disagree
/// with the tag, which is the whole thing being avoided.
let composeVersion = "0.0.0-dev"

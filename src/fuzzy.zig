//! Tiny fuzzy matcher for the pickers.
//!
//! `score` returns null when `query` is not a subsequence of `candidate`
//! (case-insensitive), otherwise a higher-is-better score that rewards
//! consecutive matches and matches at word boundaries — enough to float the
//! obvious result to the top without a full fzf-style algorithm.

const std = @import("std");

pub fn score(candidate: []const u8, query: []const u8) ?i32 {
    if (query.len == 0) return 0;

    var s: i32 = 0;
    var qi: usize = 0;
    var prev_matched = false;
    for (candidate, 0..) |c, i| {
        if (qi >= query.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) {
            s += 1;
            if (prev_matched) s += 6; // consecutive run
            if (i == 0 or isBoundary(candidate[i - 1])) s += 10; // word start
            qi += 1;
            prev_matched = true;
        } else {
            prev_matched = false;
        }
    }
    if (qi < query.len) return null;
    // Prefer shorter candidates on ties.
    return s - @as(i32, @intCast(candidate.len / 4));
}

fn isBoundary(c: u8) bool {
    return c == '/' or c == '_' or c == '-' or c == '.' or c == ' ';
}

/// Helix-style multi-term matching: the query splits on spaces (a run of
/// spaces is one separator; leading/trailing spaces are ignored) and every
/// term must independently match `candidate`, in any order. The total is the
/// sum of the per-term scores, so `score`'s shorter-candidate tiebreak
/// carries over. No terms at all (an empty or all-space query) matches
/// everything, and a single term scores exactly as `score` does.
pub fn scoreTerms(candidate: []const u8, query: []const u8) ?i32 {
    var total: i32 = 0;
    var any = false;
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    while (it.next()) |term| {
        total += score(candidate, term) orelse return null;
        any = true;
    }
    return if (any) total else 0;
}

test "matches subsequence" {
    try std.testing.expect(score("src/main.zig", "main") != null);
    try std.testing.expect(score("src/main.zig", "smz") != null);
    try std.testing.expect(score("src/main.zig", "xyz") == null);
}

test "boundary and consecutive beat scattered" {
    const a = score("src/editor.zig", "editor").?; // consecutive, word start
    const b = score("seedlibtor.zig", "editor").?; // scattered
    try std.testing.expect(a > b);
}

test "empty query matches" {
    try std.testing.expectEqual(@as(?i32, 0), score("anything", ""));
}

/// A cheap 64-bit "character bag" for prefiltering (the trick Zed's fuzzy
/// matcher uses): one bit per letter/digit class, case-insensitive. A
/// candidate can only match a query if the query's bag is a subset of the
/// candidate's — checked with two ANDs before running the real scorer.
pub fn charMask(s: []const u8) u64 {
    var m: u64 = 0;
    for (s) |raw| {
        const c = std.ascii.toLower(raw);
        if (c >= 'a' and c <= 'z') {
            m |= @as(u64, 1) << @intCast(c - 'a');
        } else if (c >= '0' and c <= '9') {
            m |= @as(u64, 1) << @intCast(26 + (c - '0'));
        } else {
            m |= @as(u64, 1) << 36; // any other byte
        }
    }
    return m;
}

/// True when `query_mask` chars all appear in the candidate's mask.
pub fn maskMatches(candidate_mask: u64, query_mask: u64) bool {
    return (query_mask & ~candidate_mask) == 0;
}

/// The query side of the prefilter for multi-term queries: the union of the
/// terms' masks. A space is query syntax (the term separator), not a
/// character the candidate must contain, so it contributes no bit. Still a
/// sound necessary condition: every term's characters must appear in a
/// matching candidate, hence so must their union.
pub fn queryMask(s: []const u8) u64 {
    var m: u64 = 0;
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |term| m |= charMask(term);
    return m;
}

test "charMask prefilters" {
    const path = charMask("src/main.zig");
    try std.testing.expect(maskMatches(path, charMask("main")));
    try std.testing.expect(maskMatches(path, charMask("SMZ"))); // case-insensitive
    try std.testing.expect(!maskMatches(path, charMask("query"))); // q,e,y absent
    try std.testing.expect(maskMatches(charMask("a1/b2.txt"), charMask("12")));
}

test "multi-term: every term must match, in any order" {
    const both = "src/editor/render.zig";
    try std.testing.expect(scoreTerms(both, "render editor") != null);
    try std.testing.expect(scoreTerms(both, "editor render") != null);
    // The sum is order-independent, so both orders score the same.
    try std.testing.expectEqual(scoreTerms(both, "render editor"), scoreTerms(both, "editor render"));
    // One term matching nothing rejects the candidate outright.
    try std.testing.expect(scoreTerms(both, "editor qqq") == null);
    try std.testing.expect(scoreTerms("src/main.zig", "main editor") == null);
}

test "multi-term: space runs and edge spaces are separators only" {
    try std.testing.expectEqual(scoreTerms("a b", "a b"), scoreTerms("a b", "a  b"));
    try std.testing.expectEqual(scoreTerms("src/main.zig", "main"), scoreTerms("src/main.zig", "  main  "));
    try std.testing.expectEqual(@as(?i32, 0), scoreTerms("anything", ""));
    try std.testing.expectEqual(@as(?i32, 0), scoreTerms("anything", "   "));
}

test "multi-term: each term runs over the whole candidate, consuming nothing" {
    // Helix's rule, and the reason terms may overlap: a term is matched
    // against the *full* candidate, not against what earlier terms left.
    // "tree.zig" holds two 'e's — enough for "ee" and, separately, for "e" —
    // but never enough for a single "eee".
    try std.testing.expect(scoreTerms("tree.zig", "ee e") != null);
    try std.testing.expect(scoreTerms("tree.zig", "eee") == null);
    try std.testing.expect(scoreTerms("tree.zig", "tree tree zig") != null);
}

test "multi-term: consecutive/boundary matches still outrank scattered ones" {
    // The per-term sum must not flatten `score`'s ranking.
    const tight = scoreTerms("sub/gamma.txt", "sub gamma").?; // both at word starts
    const loose = scoreTerms("stubs/grammar.txt", "sub gamma").?; // both scattered
    try std.testing.expect(tight > loose);
}

test "multi-term: single-term behaviour is byte-identical to score" {
    const candidates = [_][]const u8{
        "src/main.zig", "src/editor.zig",            "seedlibtor.zig",
        "README.md",    "a1/b2.txt",                 "doc/zedit.1",
        "vendor/ts",    "tools/scenarios/picker.zig",
    };
    const queries = [_][]const u8{ "", "main", "smz", "xyz", "editor", "zig", "Q", "picker", "doc1" };
    for (candidates) |c| for (queries) |q|
        try std.testing.expectEqual(score(c, q), scoreTerms(c, q));
}

test "queryMask skips the separators" {
    try std.testing.expectEqual(charMask("readme"), queryMask("read me"));
    // "README" holds no 'other' byte, so a spaced query's charMask (bit 36
    // from the space) would wrongly reject it — queryMask must not.
    try std.testing.expect(maskMatches(charMask("README"), queryMask("read me")));
    try std.testing.expect(!maskMatches(charMask("README"), charMask("read me")));
    try std.testing.expect(!maskMatches(charMask("README"), queryMask("read query")));
    // A query of separators alone constrains nothing — the prefilter must
    // agree with `scoreTerms`, which matches every candidate for it.
    try std.testing.expectEqual(@as(u64, 0), queryMask("   "));
    try std.testing.expect(maskMatches(charMask("README"), queryMask("   ")));
}

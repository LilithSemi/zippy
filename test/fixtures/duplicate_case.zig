// The `2 =>` arm's body (`1 + x`) duplicates the `1 =>` arm's body (`x +
// 1`) -- commutative addition makes them structurally identical, exactly
// what duplicate_case flags.
fn classify(n: u8, x: u8) u8 {
    return switch (n) {
        1 => x + 1,
        2 => 1 + x,
        else => 0,
    };
}

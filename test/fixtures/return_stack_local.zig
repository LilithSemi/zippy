pub fn bad() *const u8 {
    const v: u8 = 42;
    return &v;
}

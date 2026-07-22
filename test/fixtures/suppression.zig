pub fn f() void {
    // zippy:ignore discarded_error
    _ = g();
    _ = g();
}
pub fn g() u8 {
    return 0;
}

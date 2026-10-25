// Shared stimulus for the float unit testbenches; the includer declares EXP_W, MAN_W, W and logic [W-1:0] va[$], vb[$].
// Every special class against every other, multiplier exponent edges, adder cancellations and alignment shifts, then random pairs.

function automatic logic [W-1:0] fp_mk(input bit s, input int e, input longint m);
  return {s, EXP_W'(e), MAN_W'(m)};
endfunction

// As the fp32 testbenches: subnormal exponents to 1, infinity/NaN exponents to the largest finite one.
function automatic logic [W-1:0] fix_random_input(input logic [W-1:0] v);
  if (v[W-2:MAN_W] == '0) return {v[W-1], EXP_W'(1), v[MAN_W-1:0]};
  if (v[W-2:MAN_W] == '1) return {v[W-1], EXP_W'((1 << EXP_W) - 2), v[MAN_W-1:0]};
  return v;
endfunction

task automatic build_stimulus(input int n_random);
  automatic int bias = (1 << (EXP_W - 1)) - 1;
  automatic int emax = (1 << EXP_W) - 1;
  automatic int max_e = emax - 1;
  automatic longint mmax = (longint'(1) << MAN_W) - 1;
  logic [W-1:0] special[$];
  for (int s = 0; s < 2; s++) begin
    special.push_back(fp_mk(s, 0, 0));  // zero
    special.push_back(fp_mk(s, 0, 1));  // subnormal patterns, read as zero
    special.push_back(fp_mk(s, 0, mmax));
    special.push_back(fp_mk(s, 1, 0));  // smallest normals
    special.push_back(fp_mk(s, 1, mmax));
    special.push_back(fp_mk(s, max_e, mmax));  // largest normal
    special.push_back(fp_mk(s, bias, 0));  // 1.0
    special.push_back(fp_mk(s, bias, mmax));  // just under 2.0
    special.push_back(fp_mk(s, emax, 0));  // infinity
    special.push_back(fp_mk(s, emax, longint'(1) << (MAN_W - 1)));  // quiet NaN
    special.push_back(fp_mk(s, emax, 1));  // signaling NaN
  end
  foreach (special[i])
    foreach (special[j]) begin
      va.push_back(special[i]);
      vb.push_back(special[j]);
    end
  // Multiplier edges: exponent sums around the bias (underflow) and around emax + bias (overflow), plain and all-ones mantissas.
  for (int ea = 1; ea <= max_e; ea++)
    for (int k = -4; k <= 4; k++)
      for (int t = 0; t < 2; t++) begin
        automatic int lo = bias - ea + k;
        automatic int hi = emax + bias - 1 - ea + k;
        automatic longint mx = t ? mmax : longint'($urandom);
        if (lo >= 1 && lo <= max_e) begin
          va.push_back(fp_mk($urandom_range(0, 1), ea, mx));
          vb.push_back(fp_mk($urandom_range(0, 1), lo, t ? mmax : longint'($urandom)));
        end
        if (hi >= 1 && hi <= max_e) begin
          va.push_back(fp_mk($urandom_range(0, 1), ea, mx));
          vb.push_back(fp_mk($urandom_range(0, 1), hi, t ? mmax : longint'($urandom)));
        end
      end
  // Adder edges: cancellations at the bottom of the range, exact cancellation, and every alignment shift past the sticky collapse.
  for (int e = 1; e <= MAN_W + 6; e++)
    for (int k = 0; k < 8; k++) begin
      automatic logic [W-1:0] x = fp_mk(0, e, longint'($urandom));
      automatic logic [W-1:0] y = x + W'($urandom_range(0, 3));
      va.push_back(x);
      vb.push_back({1'b1, y[W-2:0]});
      va.push_back({1'b1, x[W-2:0]});
      vb.push_back(x);
    end
  for (int d = 0; d <= MAN_W + 6; d++)
    for (int k = 0; k < 8; k++) begin
      automatic int ea = $urandom_range(d + 1, max_e);
      va.push_back(fp_mk(0, ea, longint'($urandom)));
      vb.push_back(fp_mk($urandom_range(0, 1), ea - d, longint'($urandom)));
    end
  for (int k = 0; k < 16; k++) begin  // sums that overflow
    va.push_back(fp_mk(0, max_e, longint'($urandom)));
    vb.push_back(fp_mk(0, max_e - (k % 2), longint'($urandom)));
  end
  // Random: mostly normal operands as in the fp32 testbenches, one in eight raw so every class appears.
  for (int i = 0; i < n_random; i++) begin
    automatic logic [W-1:0] ra = W'({$urandom, $urandom});
    automatic logic [W-1:0] rb = W'({$urandom, $urandom});
    if (i % 8 != 0) begin
      ra = fix_random_input(ra);
      rb = fix_random_input(rb);
    end
    va.push_back(ra);
    vb.push_back(rb);
  end
endtask

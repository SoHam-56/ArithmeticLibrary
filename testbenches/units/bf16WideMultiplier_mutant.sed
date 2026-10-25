# product_lsb_dropped: the significand product's lowest bit is cleared when the product is at least 2 (make bf16WideMultiplier-mutant must see its bench FAIL)
/^    normalized_mantissa = s2_significand_product\[PRODUCT_WIDTH-1\] ? /a\    normalized_mantissa[8] = 1'b0;

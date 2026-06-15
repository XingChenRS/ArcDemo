#pragma once

#include <stdint.h>
#include <stdbool.h>

bool judge_window_install(uint64_t image_base);
bool judge_window_set_thresholds_ms(int max_ms, int pure_ms, int far_ms, int lost_ms);
bool judge_window_is_active(void);
const char *judge_window_install_log(void);

void judge_window_get_thresholds_ms(int *max_ms, int *pure_ms, int *far_ms, int *lost_ms);

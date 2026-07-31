`timescale 1ns / 1ps
// Module: Whack-a-Mole game controller
module whack_a_mole_game #(
    parameter int CLK_FREQ_HZ        = 50_000_000, // System clock frequency, default 50 MHz
    parameter bit KEY_ACTIVE_LOW     = 1'b1,      // Keys active-low? (set to 1 if a pressed key reads 0)
    parameter bit SEG_ACTIVE_LOW     = 1'b1,      // Segment outputs active-low?
    parameter bit DIG_ACTIVE_LOW     = 1'b0,      // Digit enables are active-high (common-anode digit select driven high)

    parameter int WIN_TARGET         = 20,        // Win target: clear 20 moles
    parameter int MAX_CHANCE         = 4,         // Initial lives: 4 chances
    parameter int ROUND_TIME_MS      = 1000,      // Mole on-screen time per round (1 second)
    parameter int SCAN_FREQ_HZ       = 1000,      // Display scan frequency (1 kHz, 1 ms period)
    parameter int SHORT_BEEP_MS      = 150,       // Buzzer beep duration when a chance is lost
    parameter int END_MUSIC_MS       = 1800       // End-of-game animation/music duration
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic [3:0]  key,     // 4 hit keys, mapped to positions SM4~SM1
    input  logic        hard_mode, // Hard-mode switch: 1 = two moles per round (at most one big), 0 = classic single-mole mode

    output logic [3:0]  led,     // 4 LEDs showing remaining chances M
    output logic [6:0]  seg,     // 7-segment segment outputs (a-g)
    output logic [5:0]  dig,     // Digit select (6-digit display)
    output logic        buzzer   // Buzzer output
);

    // ============================================================
    // 1. Constant conversion: time (ms) to clock tick counts
    // ============================================================
    localparam int ROUND_TICKS      = CLK_FREQ_HZ / 1000 * ROUND_TIME_MS;
    localparam int SHORT_BEEP_TICKS = CLK_FREQ_HZ / 1000 * SHORT_BEEP_MS;
    localparam int END_MUSIC_TICKS  = CLK_FREQ_HZ / 1000 * END_MUSIC_MS;
    localparam int SCAN_DIV         = CLK_FREQ_HZ / SCAN_FREQ_HZ;

    // ============================================================
    // 2. FSM state definitions
    // ============================================================
    typedef enum logic [1:0] {
        ST_INIT, // Idle state: wait for start, display 00, all LEDs on
        ST_RUN,  // Running state: moles appear, player hits them
        ST_WIN,  // Win state: play music, then return to idle
        ST_LOSE  // Lose state: play music, then return to idle
    } state_t;

    state_t state, state_n;

    // ============================================================
    // 3. Signal declarations
    // ============================================================
    logic [$clog2(ROUND_TICKS):0] round_cnt;    // Per-round mole timer
    logic [2:0] chance_m;                       // Remaining chances M (0~4)
    logic [5:0] kill_n;                         // Cleared-mole count N (0~21: a hard-mode double kill can overshoot WIN_TARGET by 1)
    logic [1:0] mole_hp [3:0];                  // Mole HP at each of the 4 positions (0: none, 1: small, 2: big)
    logic [7:0] lfsr;                           // Linear feedback shift register for pseudo-random numbers

    logic short_beep_active;                    // Short-beep enable flag
    logic [$clog2(SHORT_BEEP_TICKS):0] beep_cnt; // Beep timer
    logic [$clog2(END_MUSIC_TICKS):0] music_cnt; // End-music timer

    // ============================================================
    // 4. Display scan and 1 ms tick generation
    // ============================================================
    logic [2:0] scan_idx;
    logic [15:0] scan_div_cnt;
        logic tick_1ms; // 1 ms tick pulse, used for debouncing

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_div_cnt <= 0;
            scan_idx <= 0;
        end else begin
            if (scan_div_cnt >= SCAN_DIV - 1) begin
                scan_div_cnt <= 0;
                scan_idx <= (scan_idx >= 5) ? 0 : scan_idx + 1;
            end else begin
                scan_div_cnt <= scan_div_cnt + 1;
            end
        end
    end
    assign tick_1ms = (scan_div_cnt == SCAN_DIV - 1); // Pulses high once every 1 ms

    // ============================================================
    // 5. Key debouncing + single-pulse detection (8 ms qualification)
    // ============================================================
        logic [7:0] key_shift [3:0]; // 8-bit shift registers recording the last 8 ms of key state
        logic [3:0] key_stable;      // Debounced stable state
        logic [3:0] key_stable_dly;  // Stable state delayed one cycle, for edge detection
        logic [3:0] key_press;       // Final clean single-shot key-press pulse

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for(int i=0; i<4; i++) begin
                key_shift[i] <= 8'd0;
                key_stable[i] <= 1'b0;
            end
            key_stable_dly <= 4'd0;
        end else begin
            key_stable_dly <= key_stable; // Save the previous-cycle state

            if (tick_1ms) begin // Sample the physical keys every 1 ms
                for(int i=0; i<4; i++) begin
                    // Handle the active level and shift in the new sample
                    key_shift[i] <= {key_shift[i][6:0], KEY_ACTIVE_LOW ? ~key[i] : key[i]};

                    // Only treat as pressed after 8 ms of continuous 1s; only treat as released after 8 ms of continuous 0s
                    if (key_shift[i] == 8'hFF)
                        key_stable[i] <= 1'b1;
                    else if (key_shift[i] == 8'h00)
                        key_stable[i] <= 1'b0;
                end
            end
        end
    end
    // Rising-edge detection: the single clock cycle where the stable state goes 0->1 triggers one hit
    assign key_press = key_stable & ~key_stable_dly;

    // ============================================================
    // 6. LFSR pseudo-random generation (decides mole position/size)
    // ============================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= 8'hA5;
        end else begin
            // Keep the LFSR free-running at 50 MHz in the background!
            // The unpredictable time the player idles in ST_INIT forms a perfect true-random seed
            lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
        end
    end

    // Hard-mode switch synchronizer: the external DIP switch is an asynchronous input, two flops remove metastability
    logic [1:0] hard_mode_sync;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) hard_mode_sync <= 2'b00;
        else        hard_mode_sync <= {hard_mode_sync[0], hard_mode};
    end

    // Spawn position decode: the first mole's position is lfsr[1:0];
    // the second position = first position XOR a non-zero offset, guaranteeing the two positions always differ
    logic [1:0] spawn_pos1, spawn_pos2;
    assign spawn_pos1 = lfsr[1:0];
    assign spawn_pos2 = spawn_pos1 ^ ((lfsr[5:4] == 2'b00) ? 2'b01 : lfsr[5:4]);

    // ============================================================
    // 7. Main game FSM
    // ============================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_INIT;
        end else begin
            state <= state_n;
        end
    end

    // State transition logic
    always_comb begin
        state_n = state;
        case (state)
            ST_INIT: if (|key_press) state_n = ST_RUN; // Press any key to start
            ST_RUN: begin
                if (kill_n >= WIN_TARGET) state_n = ST_WIN;   // Reaching 20 cleared moles wins
                else if (chance_m == 0)   state_n = ST_LOSE;  // Running out of chances loses
            end
            ST_WIN, ST_LOSE: begin
                if (music_cnt >= END_MUSIC_TICKS) state_n = ST_INIT; // Reset after the music finishes
            end
        endcase
    end

    // ============================================================
    // 8. Core game counting and judging logic
    // ============================================================
    // Number of moles fully cleared this cycle (HP 1->0). In hard mode two
    // moles can be killed in the very same cycle, so the kills must be summed
    // in parallel — repeatedly assigning kill_n inside the loop would drop one
    logic [2:0] kills_now;
    always_comb begin
        kills_now = '0;
        for (int i = 0; i < 4; i++)
            if (key_press[i] && mole_hp[i] == 2'd1)
                kills_now += 3'd1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chance_m <= MAX_CHANCE[2:0];
            kill_n   <= 0;
            round_cnt <= 0;
            short_beep_active <= 0;
            beep_cnt <= 0;
            for(int i=0; i<4; i++) mole_hp[i] <= 0;
        end else begin
            case (state)
                ST_INIT: begin
                    chance_m <= MAX_CHANCE[2:0];
                    kill_n   <= 0;
                    music_cnt <= 0;
                    round_cnt <= 0;
                    short_beep_active <= 0;
                    beep_cnt <= 0;
                    for(int i=0; i<4; i++) mole_hp[i] <= 0;
                end

                ST_RUN: begin
                    // --- Hit detection ---
                    for (int i=0; i<4; i++) begin
                        if (key_press[i] && mole_hp[i] > 0) begin
                            mole_hp[i] <= mole_hp[i] - 1'b1; // Decrease HP (2->1 or 1->0)
                        end
                    end
                    kill_n <= kill_n + kills_now; // HP going 1 to 0 means fully cleared, add to score

                    // --- Round timing and chance deduction ---
                    if (round_cnt >= ROUND_TICKS - 1) begin
                        round_cnt <= 0;

                        // If a mole is still alive when the round ends, deduct 1 chance
                        if (|{mole_hp[0], mole_hp[1], mole_hp[2], mole_hp[3]}) begin
                            if (chance_m > 0) chance_m <= chance_m - 1;
                            short_beep_active <= 1; // Trigger the short beep
                        end

                        // Spawn new moles: classic mode spawns 1 per round (position/size from the LFSR);
                        // hard mode spawns 2 per round (always at different positions), with the second
                        // one fixed as a small mole so at most one big mole is on screen
                        for (int i = 0; i < 4; i++) begin
                            if (i == spawn_pos1)
                                mole_hp[i] <= (lfsr[3:2] == 2'b11) ? 2'd2 : 2'd1;
                            else if (hard_mode_sync[1] && i == spawn_pos2)
                                mole_hp[i] <= 2'd1;
                            else
                                mole_hp[i] <= 2'd0;
                        end
                    end else begin
                        round_cnt <= round_cnt + 1;
                    end

                    // Short-beep timing
                    if (short_beep_active) begin
                        if (beep_cnt >= SHORT_BEEP_TICKS - 1) begin
                            beep_cnt <= 0;
                            short_beep_active <= 0;
                        end else begin
                            beep_cnt <= beep_cnt + 1;
                        end
                    end
                end

                ST_WIN, ST_LOSE: begin
                    music_cnt <= music_cnt + 1;
                end
            endcase
        end
    end

    // ============================================================
    // 9. LED chance display logic
    // ============================================================
    always_comb begin
        case (chance_m)
            3: led = 4'b0111;
            2: led = 4'b0011;
            1: led = 4'b0001;
            0: led = 4'b0000;
            default: led = 4'b1111; // Initial state or full lives
        endcase
    end

    // ============================================================
    // 10. Multiplexed 7-segment display (SM6~SM1)
    // ============================================================
    logic [3:0] current_digit_val;

    // Select what the currently scanned digit shows based on the scan index
    always_comb begin
        case (scan_idx)
            5: current_digit_val = kill_n / 10; // SM6: cleared count, tens digit
            4: current_digit_val = kill_n % 10; // SM5: cleared count, ones digit
            3: current_digit_val = (mole_hp[3]==2) ? 4'hB : (mole_hp[3]==1 ? 4'hA : 4'hF); // SM4
            2: current_digit_val = (mole_hp[2]==2) ? 4'hB : (mole_hp[2]==1 ? 4'hA : 4'hF); // SM3
            1: current_digit_val = (mole_hp[1]==2) ? 4'hB : (mole_hp[1]==1 ? 4'hA : 4'hF); // SM2
            0: current_digit_val = (mole_hp[0]==2) ? 4'hB : (mole_hp[0]==1 ? 4'hA : 4'hF); // SM1
            default: current_digit_val = 4'hF;
        endcase
    end

    // 7-segment decoder function
    function automatic logic [6:0] decode(input logic [3:0] v);
        case (v)
            4'h0: decode = 7'b1111110; 4'h1: decode = 7'b0110000;
            4'h2: decode = 7'b1101101; 4'h3: decode = 7'b1111001;
            4'h4: decode = 7'b0110011; 4'h5: decode = 7'b1011011;
            4'h6: decode = 7'b1011111; 4'h7: decode = 7'b1110000;
            4'h8: decode = 7'b1111111; 4'h9: decode = 7'b1111011;
            4'hA: decode = 7'b0011100; // Small-mole pattern (u)
            4'hB: decode = 7'b1111111; // Big-mole pattern
            default: decode = 7'b0000000; // 4'hF blank / all segments off
        endcase
    endfunction

    // Drive the physical pins
    assign seg = (SEG_ACTIVE_LOW) ? ~decode(current_digit_val) : decode(current_digit_val);

    always_comb begin
        logic [5:0] dig_tmp;
        dig_tmp = 6'b000000;
        dig_tmp[scan_idx] = 1'b1;
        dig = (DIG_ACTIVE_LOW) ? ~dig_tmp : dig_tmp;
    end

    // ============================================================
    // 11. Buzzer tone generation
    // ============================================================
    logic [17:0] tone_cnt;
    logic [17:0] tone_period;

    // Frequency = system clock / tone_period
    // Examples: 50M/50000 = 1 kHz   50M/250000 = 200 Hz   50M/100000 = 500 Hz
    assign tone_period = (state == ST_WIN)  ? 18'd50000 :
                         (state == ST_LOSE) ? 18'd250000 :
                                              18'd100000;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tone_cnt <= 0;
        end else begin
            if (tone_cnt >= tone_period - 1)
                tone_cnt <= 0;
            else
                tone_cnt <= tone_cnt + 1;
        end
    end

    // 50% duty cycle: output high while the count is below half the period, producing a square wave
    assign buzzer = (short_beep_active || state == ST_WIN || state == ST_LOSE)
                    ? (tone_cnt < (tone_period >> 1))
                    : 1'b0;

endmodule

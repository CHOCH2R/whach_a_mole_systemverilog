`timescale 1ns / 1ps
// 模块名：打地鼠游戏控制器
module whack_a_mole_game #(
    parameter int CLK_FREQ_HZ        = 50_000_000, // 系统时钟频率，默认50MHz
    parameter bit KEY_ACTIVE_LOW     = 1'b1,      // 按键是否低电平有效（按下为0则设为1）
    parameter bit SEG_ACTIVE_LOW     = 1'b1,      // 数码管段选是否低电平点亮
    parameter bit DIG_ACTIVE_LOW     = 1'b0,      // 数码管位选应为高电平使能 (共阳极数码管位选接高电平)

    parameter int WIN_TARGET         = 20,        // 胜利目标：消除20个
    parameter int MAX_CHANCE         = 4,         // 初始生命值：4次机会
    parameter int ROUND_TIME_MS      = 1000,      // 地鼠每轮停留时间（1秒）
    parameter int SCAN_FREQ_HZ       = 1000,      // 数码管扫描频率（1kHz，周期1ms）
    parameter int SHORT_BEEP_MS      = 150,       // 扣血时蜂鸣器响多久
    parameter int END_MUSIC_MS       = 1800       // 游戏结束动画/音乐时长
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic [3:0]  key,     // 4个打击按键，对应SM4~SM1位置
    input  logic        hard_mode, // 困难模式开关：1=每轮同时出现两只地鼠（至多一只大地鼠），0=经典单只模式

    output logic [3:0]  led,     // 4个LED，代表剩余生命值M
    output logic [6:0]  seg,     // 数码管段选（a-g）
    output logic [5:0]  dig,     // 数码管位选（6位数码管）
    output logic        buzzer   // 蜂鸣器输出
);

    // ============================================================
    // 1. 常量换算：将时间(ms)转换为时钟计数值(Ticks)
    // ============================================================
    localparam int ROUND_TICKS      = CLK_FREQ_HZ / 1000 * ROUND_TIME_MS;
    localparam int SHORT_BEEP_TICKS = CLK_FREQ_HZ / 1000 * SHORT_BEEP_MS;
    localparam int END_MUSIC_TICKS  = CLK_FREQ_HZ / 1000 * END_MUSIC_MS;
    localparam int SCAN_DIV         = CLK_FREQ_HZ / SCAN_FREQ_HZ;

    // ============================================================
    // 2. 状态机定义
    // ============================================================
    typedef enum logic [1:0] {
        ST_INIT, // 初始状态：等待开始，显示00，LED全亮
        ST_RUN,  // 运行状态：地鼠出现，玩家打击
        ST_WIN,  // 胜利状态：播音乐，回到初始
        ST_LOSE  // 失败状态：播音乐，回到初始
    } state_t;

    state_t state, state_n;

    // ============================================================
    // 3. 信号定义
    // ============================================================
    logic [$clog2(ROUND_TICKS):0] round_cnt;    // 每轮地鼠计秒器
    logic [2:0] chance_m;                       // 剩余机会M (0~4)
    logic [5:0] kill_n;                         // 消除数量N (0~21，困难模式同拍双杀可超出目标1个)
    logic [1:0] mole_hp [3:0];                  // 4个位置地鼠的血量(0:无, 1:小, 2:大)
    logic [7:0] lfsr;                           // 线性反馈移位寄存器，用于产生伪随机数
    
    logic short_beep_active;                    // 蜂鸣器短响使能信号
    logic [$clog2(SHORT_BEEP_TICKS):0] beep_cnt; // 蜂鸣器计时
    logic [$clog2(END_MUSIC_TICKS):0] music_cnt; // 结束音乐计时

    // ============================================================
    // 4. 数码管扫描与 1ms 脉冲生成
    // ============================================================
    logic [2:0] scan_idx;
    logic [15:0] scan_div_cnt;
        logic tick_1ms; // 1ms 节拍脉冲，用于消抖

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
    assign tick_1ms = (scan_div_cnt == SCAN_DIV - 1); // 每 1ms 产生一次高电平

    // ============================================================
    // 5. 按键消抖处理 (Debounce) + 单脉冲检测 (8ms 判定)
    // ============================================================
        logic [7:0] key_shift [3:0]; // 8位移位寄存器，记录最近8ms的按键状态
        logic [3:0] key_stable;      // 消抖后的稳定状态
        logic [3:0] key_stable_dly;  // 稳定状态打一拍，用于捕捉边沿
        logic [3:0] key_press;       // 最终安全有效的单次按键脉冲

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for(int i=0; i<4; i++) begin
                key_shift[i] <= 8'd0;
                key_stable[i] <= 1'b0;
            end
            key_stable_dly <= 4'd0;
        end else begin
            key_stable_dly <= key_stable; // 保存上一拍状态
            
            if (tick_1ms) begin // 每 1ms 采样一次物理按键
                for(int i=0; i<4; i++) begin
                    // 处理高低电平有效，并将新状态移入
                    key_shift[i] <= {key_shift[i][6:0], KEY_ACTIVE_LOW ? ~key[i] : key[i]};
                    
                    // 连续8ms都是按下(全1)，才认为真正按下；连续8ms松开(全0)，才认为真正松开
                    if (key_shift[i] == 8'hFF) 
                        key_stable[i] <= 1'b1;
                    else if (key_shift[i] == 8'h00) 
                        key_stable[i] <= 1'b0;
                end
            end
        end
    end
    // 上升沿检测：稳定状态从0变1的那一个时钟周期，触发一次打击
    assign key_press = key_stable & ~key_stable_dly; 

    // ============================================================
    // 6. LFSR 伪随机数生成（用于地鼠出现位置/大小判定）
    // ============================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= 8'hA5;
        end else begin
            // 让 LFSR 一直在后台以 50MHz 高速运转！
            // 玩家在 ST_INIT 状态下发呆的时间是未知的，这就形成了完美的真随机种子
            lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
        end
    end

    // 困难模式开关同步：外部拨码开关为异步输入，打两拍消除亚稳态
    logic [1:0] hard_mode_sync;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) hard_mode_sync <= 2'b00;
        else        hard_mode_sync <= {hard_mode_sync[0], hard_mode};
    end

    // 地鼠生成位置译码：第一只位置取 lfsr[1:0]；
    // 第二只位置 = 第一只位置 异或 一个非零偏移，保证两只位置必然不同
    logic [1:0] spawn_pos1, spawn_pos2;
    assign spawn_pos1 = lfsr[1:0];
    assign spawn_pos2 = spawn_pos1 ^ ((lfsr[5:4] == 2'b00) ? 2'b01 : lfsr[5:4]);

    // ============================================================
    // 7. 游戏主逻辑状态机
    // ============================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_INIT;
        end else begin
            state <= state_n;
        end
    end

    // 状态跳转逻辑
    always_comb begin
        state_n = state;
        case (state)
            ST_INIT: if (|key_press) state_n = ST_RUN; // 按任意键开始
            ST_RUN: begin
                if (kill_n >= WIN_TARGET) state_n = ST_WIN;   // 达到20个胜利
                else if (chance_m == 0)   state_n = ST_LOSE;  // 机会用完失败
            end
            ST_WIN, ST_LOSE: begin
                if (music_cnt >= END_MUSIC_TICKS) state_n = ST_INIT; // 音乐播完复位
            end
        endcase
    end

    // ============================================================
    // 8. 游戏核心计数与判定逻辑
    // ============================================================
    // 本拍完全消除的地鼠数（血量 1->0）。困难模式下两只地鼠可能在
    // 同一拍被同时打死，必须并行累加，不能在循环里对 kill_n 重复赋值
    logic [2:0] kills_now;
    always_comb begin
        kills_now = '0;
        for (int i = 0; i < 4; i++)
            if (key_press[i] && mole_hp[i] == 2'd1)
                kills_now += 3'd1;
    end

    // 本拍打击结算后各位置是否仍有地鼠存活（用于到期扣血判定与清屏检测）
    logic [3:0] mole_alive_next;
    logic any_alive_now, any_alive_next, board_cleared_now;
    always_comb begin
        for (int i = 0; i < 4; i++)
            mole_alive_next[i] = (mole_hp[i] != 2'd0) && !(key_press[i] && mole_hp[i] == 2'd1);
    end
    assign any_alive_now     = (mole_hp[0] != 2'd0) || (mole_hp[1] != 2'd0) || (mole_hp[2] != 2'd0) || (mole_hp[3] != 2'd0);
    assign any_alive_next    = |mole_alive_next;
    assign board_cleared_now = any_alive_now && !any_alive_next;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chance_m <= MAX_CHANCE[2:0];
            kill_n   <= 0;
            round_cnt <= 0;
            music_cnt <= 0;
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
                    // --- 打击判定 ---
                    for (int i=0; i<4; i++) begin
                        if (key_press[i] && mole_hp[i] > 0) begin
                            mole_hp[i] <= mole_hp[i] - 1'b1; // 减血（2->1 或 1->0）
                        end
                    end
                    kill_n <= kill_n + kills_now; // 血量由1变0即完全消除并计分

                    // --- 回合计时、机会扣除与生成新地鼠 ---
                    if (board_cleared_now) begin
                        // 地鼠被全部消灭（哪怕恰好在到期那一拍）：回合计时器清零
                        // 重新计时，下一波地鼠在最后一击的一个完整回合之后才出现
                        round_cnt <= 0;
                    end else if (round_cnt >= ROUND_TICKS - 1) begin
                        round_cnt <= 0;
                        
                        // 回合到期仍有地鼠存活则扣 1 次机会（按本拍打击结算后的状态判断）
                        if (any_alive_next) begin
                            if (chance_m > 0) chance_m <= chance_m - 1;
                            short_beep_active <= 1; // 触发短响
                        end
                        
                        // 生成新地鼠：普通模式每轮 1 只（位置/大小由 LFSR 决定）；
                        // 困难模式每轮 2 只（位置必不同），第二只固定为小地鼠，
                        // 保证同屏至多只有一只大地鼠
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

                    // 蜂鸣器短响计时
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
    // 9. LED 机会显示逻辑
    // ============================================================
    always_comb begin
        case (chance_m)
            3: led = 4'b0111;
            2: led = 4'b0011;
            1: led = 4'b0001;
            0: led = 4'b0000;
            default: led = 4'b1111; // 初始或满血
        endcase
    end

    // ============================================================
    // 10. 数码管动态扫描显示 (SM6~SM1)
    // ============================================================
    logic [3:0] current_digit_val;

    // 根据扫描索引决定当前位显示什么内容
    always_comb begin
        case (scan_idx)
            5: current_digit_val = kill_n / 10; // SM6: 消除数十位
            4: current_digit_val = kill_n % 10; // SM5: 消除数个位
            3: current_digit_val = (mole_hp[3]==2) ? 4'hB : (mole_hp[3]==1 ? 4'hA : 4'hF); // SM4
            2: current_digit_val = (mole_hp[2]==2) ? 4'hB : (mole_hp[2]==1 ? 4'hA : 4'hF); // SM3
            1: current_digit_val = (mole_hp[1]==2) ? 4'hB : (mole_hp[1]==1 ? 4'hA : 4'hF); // SM2
            0: current_digit_val = (mole_hp[0]==2) ? 4'hB : (mole_hp[0]==1 ? 4'hA : 4'hF); // SM1
            default: current_digit_val = 4'hF;
        endcase
    end

    // 七段译码器函数
    function automatic logic [6:0] decode(input logic [3:0] v);
        case (v)
            4'h0: decode = 7'b1111110; 4'h1: decode = 7'b0110000;
            4'h2: decode = 7'b1101101; 4'h3: decode = 7'b1111001;
            4'h4: decode = 7'b0110011; 4'h5: decode = 7'b1011011;
            4'h6: decode = 7'b1011111; 4'h7: decode = 7'b1110000;
            4'h8: decode = 7'b1111111; 4'h9: decode = 7'b1111011;
            4'hA: decode = 7'b0011100; // 小地鼠图案 (u)
            4'hB: decode = 7'b1111111; // 大地鼠图案 
            default: decode = 7'b0000000; // 4'hF 空白/全灭
        endcase
    endfunction

    // 输出到物理管脚
    assign seg = (SEG_ACTIVE_LOW) ? ~decode(current_digit_val) : decode(current_digit_val);
    
    always_comb begin
        logic [5:0] dig_tmp;
        dig_tmp = 6'b000000;
        dig_tmp[scan_idx] = 1'b1;
        dig = (DIG_ACTIVE_LOW) ? ~dig_tmp : dig_tmp;
    end

    // ============================================================
    // 11. 蜂鸣器音频产生逻辑
    // ============================================================
    logic [17:0] tone_cnt;
    logic [17:0] tone_period;

    // 频率 = 系统时钟 / tone_period
    // 示例: 50M/50000 = 1kHz   50M/250000 = 200Hz   50M/100000 = 500Hz
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

    // 50% 占空比：当计数小于周期的一半时输出高电平，形成方波
    assign buzzer = (short_beep_active || state == ST_WIN || state == ST_LOSE)
                    ? (tone_cnt < (tone_period >> 1))
                    : 1'b0;

endmodule


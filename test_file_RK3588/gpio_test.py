import os
import time
import sys

# RK3588 GPIO 物理名与系统编号对应表
RK3588_GPIO_MAP = {
    "GPIO4_C6":   150, "GPIO0_C0":   16,  "GPIO2_B7":   79,
    "GPIO1_C6":   54,  "GPIO2_C2":   82,  "GPIO2_C1":   81,
    "GPIO2_C0":   80,  "GPIO0_C5_u": 21,  "GPIO4_B0":   136,
    "GPIO1_D6_u": 62,  "GPIO1_A7_u": 39,  "GPIO1_B0_u": 40,
    "GPIO1_B4_u": 44,  "GPIO1_B5_u": 45,  "GPIO2_C3":   83,
    "GPIO1_B3":   43,  "GPIO1_D7_u": 63,  "GPIO1_B7_u": 47,
    "GPIO0_C4":   20,  "GPIO0_C6_u": 19,
}

# 回环测试分组（保持不变）
GROUP_A = ["GPIO4_C6", "GPIO0_C0", "GPIO2_B7", "GPIO1_C6", "GPIO2_C2",
           "GPIO2_C1", "GPIO2_C0", "GPIO0_C5_u", "GPIO4_B0" ]
GROUP_B = ["GPIO1_A7_u", "GPIO1_B0_u", "GPIO1_B4_u", "GPIO1_B5_u", "GPIO2_C3",
           "GPIO1_B3", "GPIO1_D7_u", "GPIO1_B7_u", "GPIO0_C4" ]

# 对应的物理引脚短接对照表（与分组顺序一致）
PIN_PAIRS = [
    ("7",  "12"),   # GPIO4_C6   ↔ GPIO1_A7_u
    ("11", "16"),   # GPIO0_C0   ↔ GPIO1_B0_u ? 实际需要核对，示例沿用你提供的
    ("13", "18"),   # GPIO2_B7   ↔ GPIO1_B4_u
    ("15", "22"),   # GPIO1_C6   ↔ GPIO1_B5_u
    ("19", "24"),   # GPIO2_C2   ↔ GPIO2_C3
    ("21", "26"),   # GPIO2_C1   ↔ GPIO1_B3
    ("23", "32"),   # GPIO2_C0   ↔ GPIO1_D7_u
    ("29", "36"),   # GPIO0_C5_u ↔ GPIO1_B7_u
    ("31", "38"),   # GPIO4_B0   ↔ GPIO0_C4
]

def export_gpio(pin_num):
    path = f"/sys/class/gpio/gpio{pin_num}"
    if not os.path.exists(path):
        try:
            with open("/sys/class/gpio/export", "w") as f:
                f.write(str(pin_num))
            time.sleep(0.05)
        except Exception as e:
            print(f"  [系统提示] 导出引脚 {pin_num} 失败: {e}")

def set_direction(pin_num, direction):
    with open(f"/sys/class/gpio/gpio{pin_num}/direction", "w") as f:
        f.write(direction)

def set_value(pin_num, value):
    with open(f"/sys/class/gpio/gpio{pin_num}/value", "w") as f:
        f.write(str(value))

def read_value(pin_num):
    with open(f"/sys/class/gpio/gpio{pin_num}/value", "r") as f:
        return f.read().strip()

def single_gpio_test():
    print("\n--- 单引脚控制模式 ---")
    pin_name = input("请输入需要控制的物理GPIO名 (如 GPIO4_C6): ").strip()
    if pin_name not in RK3588_GPIO_MAP:
        print("输入错误: 不在映射表中。")
        return

    action = input("请输入动作 (high/low/read): ").strip().lower()
    pin_num = RK3588_GPIO_MAP[pin_name]
    export_gpio(pin_num)

    if action == "high":
        set_direction(pin_num, "out")
        set_value(pin_num, 1)
        print(f"[{pin_name}] 已拉高，当前读取状态: {read_value(pin_num)}")
    elif action == "low":
        set_direction(pin_num, "out")
        set_value(pin_num, 0)
        print(f"[{pin_name}] 已拉低，当前读取状态: {read_value(pin_num)}")
    elif action == "read":
        set_direction(pin_num, "in")
        print(f"[{pin_name}] 当前输入状态: {read_value(pin_num)}")
    else:
        print("动作无效。")

def loopback_test():
    print("\n--- GPIO 总线级流水灯回环测试 ---")
    print("请使用杜邦线将以下物理引脚一一短接：")
    for a, b in PIN_PAIRS:
        print(f"  物理引脚 {a:>2} <--> 物理引脚 {b:>2}")
    input("\n确认接线无误后，按回车键开始测试...")

    def test_bus(out_group, in_group, stage_name):
        print(f"\n[{stage_name}] A组与B组 对测")
        fail_count = 0
        num_pins = len(out_group)
        # 1. 批量初始化引脚方向
        for i in range(num_pins):
            export_gpio(RK3588_GPIO_MAP[out_group[i]])
            export_gpio(RK3588_GPIO_MAP[in_group[i]])
            set_direction(RK3588_GPIO_MAP[out_group[i]], "out")
            set_direction(RK3588_GPIO_MAP[in_group[i]], "in")

        # 核心验证闭包
        def apply_and_verify(pattern, desc):
            nonlocal fail_count
            # 批量设置输出
            for i in range(num_pins):
                set_value(RK3588_GPIO_MAP[out_group[i]], pattern[i])
            time.sleep(0.05) # 短暂延时等待电平在杜邦线上稳定
            # 批量读取输入
            read_pattern = []
            for i in range(num_pins):
                read_pattern.append(int(read_value(RK3588_GPIO_MAP[in_group[i]])))
            expected_str = "".join(map(str, pattern))
            read_str = "".join(map(str, read_pattern))
            if expected_str == read_str:
                print(f"  [PASS] {desc:10} 预期: {expected_str} | 读回: {read_str}")
            else:
                print(f"  [FAIL] {desc:10} 预期: {expected_str} | 读回: {read_str}")
                fail_count += 1

        # 2. 执行全 0 / 全 1 基础测试
        apply_and_verify([0] * num_pins, "全 0 测试")
        apply_and_verify([1] * num_pins, "全 1 测试")
        # 3. 执行流水灯测试 (检测引脚间短路)
        for i in range(num_pins):
            pattern = [0] * num_pins
            pattern[i] = 1
            apply_and_verify(pattern, f"位 {i+1} 流水")
        return fail_count

    total_fails = 0
    # 阶段一：A -> B
    total_fails += test_bus(GROUP_A, GROUP_B, "阶段一 (A输出 -> B读取)")
    # 阶段二：B -> A
    total_fails += test_bus(GROUP_B, GROUP_A, "阶段二 (B输出 -> A读取)")
    print(f"\n测试完成。总计失败项: {total_fails} 个")

def main():
    while True:
        print("\n" + "="*30)
        print("  RK3588 GPIO 测试工具菜单")
        print("="*30)
        print("1. 单引脚功能测试 (GPIO测试)")
        print("2. 总线级流水灯互测 (回环测试)")
        print("3. 退出")
        choice = input("请输入选项 (1-3): ").strip()
        if choice == "1":
            single_gpio_test()
        elif choice == "2":
            loopback_test()
        elif choice == "3":
            print("退出程序。")
            sys.exit(0)
        else:
            print("无效输入，请重新选择。")

if __name__ == "__main__":
    if os.geteuid() != 0:
        print("权限错误：操作 GPIO 需要 root 权限，请使用 sudo 运行此脚本！")
        sys.exit(1)
    main()

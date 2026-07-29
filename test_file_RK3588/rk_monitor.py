#!/usr/bin/env python3
import os
import time
import datetime
import re
import sys

# --- 硬件节点基础路径 ---
CPU_FREQ_BASE = "/sys/devices/system/cpu/cpu{}/cpufreq/scaling_cur_freq"
NPU_BASE = "/sys/class/devfreq/fdab0000.npu"
DDR_BASE = "/sys/class/devfreq/dmc"
NPU_DEBUG_LOAD = "/sys/kernel/debug/rknpu/load"
THERMAL_DIR = "/sys/class/thermal"

class RKMonitor:
    def __init__(self):
        self.last_cpu_times = self._get_cpu_times()
        # 动态探测 GPU 相关路径
        self.gpu_devfreq_dir = self._find_gpu_devfreq_dir()
        self.gpu_load_path = self._find_gpu_load_path()
        self._fix_npu_permission()

    def _read_val(self, path):
        """安全读取文件内容，失败返回 'N/A'"""
        if not path or not os.path.exists(path):
            return "N/A"
        try:
            with open(path, 'r') as f:
                return f.read().strip()
        except Exception:
            return "N/A"

    def _get_cpu_times(self):
        """获取 CPU 各核心的累计时间"""
        try:
            with open('/proc/stat', 'r') as f:
                lines = f.readlines()
        except:
            return {}
        cpu_times = {}
        for line in lines:
            if line.startswith('cpu') and len(line) > 3 and line[3].isdigit():
                parts = line.split()
                name = parts[0]
                idle = int(parts[4])
                total = sum(int(p) for p in parts[1:])
                cpu_times[name] = (idle, total)
        return cpu_times

    def get_cpu_load(self):
        """计算 CPU 各核心的使用率"""
        current_times = self._get_cpu_times()
        loads = {}
        for name, (idle, total) in current_times.items():
            prev_idle, prev_total = self.last_cpu_times.get(name, (0, 0))
            diff_idle = idle - prev_idle
            diff_total = total - prev_total
            if diff_total != 0:
                loads[name] = max(0.0, min(100.0, (1.0 - diff_idle / diff_total) * 100.0))
            else:
                loads[name] = 0.0
        self.last_cpu_times = current_times
        return loads

    # ------------------ GPU 路径自动探测 ------------------
    def _find_gpu_devfreq_dir(self):
        """找到包含 gpu 的 devfreq 目录路径"""
        try:
            for dev in os.listdir("/sys/class/devfreq"):
                if "gpu" in dev:
                    return f"/sys/class/devfreq/{dev}"
        except:
            pass
        # 回退到常见路径
        if os.path.exists("/sys/class/devfreq/fb000000.gpu"):
            return "/sys/class/devfreq/fb000000.gpu"
        return None

    def _find_gpu_load_path(self):
        """动态查找 GPU 负载文件"""
        # 优先使用 devfreq 内的 load 文件
        if self.gpu_devfreq_dir:
            load_file = f"{self.gpu_devfreq_dir}/load"
            if os.path.exists(load_file):
                return load_file
        # 回退到 Mali debug 节点
        if os.path.exists("/sys/kernel/debug/mali/gpu_load"):
            return "/sys/kernel/debug/mali/gpu_load"
        return None

    # ------------------ NPU 权限 ------------------
    def _fix_npu_permission(self):
        if os.path.exists(NPU_DEBUG_LOAD):
            try:
                os.chmod(NPU_DEBUG_LOAD, 0o444)
            except:
                pass

    # ------------------ GPU 负载读取 ------------------
    def _read_gpu_load(self):
        if not self.gpu_load_path:
            return "N/A"
        raw = self._read_val(self.gpu_load_path)
        if raw == "N/A":
            return "N/A"
        # 格式：百分比@频率 或 纯数字
        if "@" in raw:
            return raw.split('@')[0]
        return raw

    # ------------------ NPU 真实负载 ------------------
    def get_npu_real_load(self):
        try:
            with open(NPU_DEBUG_LOAD, 'r') as f:
                raw = f.read().strip()
            if not raw:
                return "N/A(空)"
            matches = re.findall(r"Core\s*\d+\s*:\s*(\d+)", raw, re.IGNORECASE)
            if matches:
                avg_load = sum(int(m) for m in matches) // len(matches)
                return str(avg_load)
            single_match = re.search(r"(\d+)\s*%", raw)
            return single_match.group(1) if single_match else "0"
        except PermissionError:
            return "N/A(需root)"
        except (FileNotFoundError, OSError):
            return "N/A(无节点)"
        except Exception:
            return "N/A"

    # ------------------ 主统计函数 ------------------
    def get_stats(self):
        # CPU 频率
        cpu_freqs = [self._read_val(CPU_FREQ_BASE.format(i)) for i in range(8)]

        # GPU 频率（使用探测到的 devfreq 目录）
        gpu_freq = "N/A"
        if self.gpu_devfreq_dir:
            gpu_freq = self._read_val(f"{self.gpu_devfreq_dir}/cur_freq")

        # NPU / DDR 频率
        npu_freq = self._read_val(f"{NPU_BASE}/cur_freq")
        ddr_freq = self._read_val(f"{DDR_BASE}/cur_freq")

        # 负载
        cpu_loads = self.get_cpu_load()
        gpu_load = self._read_gpu_load()
        ddr_load_raw = self._read_val(f"{DDR_BASE}/load")
        ddr_load = ddr_load_raw.split('@')[0] if "@" in ddr_load_raw else ddr_load_raw
        npu_load = self.get_npu_real_load()

        # 温度
        temps = {}
        for i in range(7):
            t_raw = self._read_val(f"{THERMAL_DIR}/thermal_zone{i}/temp")
            t_type = self._read_val(f"{THERMAL_DIR}/thermal_zone{i}/type")
            if t_raw != "N/A" and t_type != "N/A":
                temps[t_type] = f"{float(t_raw)/1000:.1f}"

        return {
            "time": datetime.datetime.now().strftime('%H:%M:%S'),
            "freqs": [f"{int(f)//1000}" if f.isdigit() else "N/A" for f in cpu_freqs],
            "loads": cpu_loads,
            "gpu_f": f"{int(gpu_freq)//1000000}" if gpu_freq.isdigit() else "N/A",
            "gpu_l": gpu_load,
            "npu_f": f"{int(npu_freq)//1000000}" if npu_freq.isdigit() else "N/A",
            "npu_l": npu_load,
            "ddr_f": f"{int(ddr_freq)//1000000}" if ddr_freq.isdigit() else "N/A",
            "ddr_l": ddr_load,
            "temps": temps
        }

# ------------------ 显示 / 日志功能保持不变 ------------------
def run_viewer(mon):
    """仪表盘实时查看模式"""
    try:
        while True:
            s = mon.get_stats()
            sys.stdout.write("\033[H\033[J")
            output = [
                "=====================================================================================",
                f"  RK3588 实时性能监控仪表盘 | 刷新时间: {s['time']}",
                "=====================================================================================",
                f"  CPU 频率 (MHz): {' '.join([f'{f:>4}' for f in s['freqs']])}",
                f"  平均 CPU 负载 : [{sum(s['loads'].values())/8:>5.1f}%]",
                "-------------------------------------------------------------------------------------",
                f"  GPU 状态 : {s['gpu_f']:>4} MHz | 负载: {s['gpu_l']:>3}%",
                f"  NPU 状态 : {s['npu_f']:>4} MHz | 平均负载: {s['npu_l']:>2}%",
                f"  DDR 状态 : {s['ddr_f']:>4} MHz | 负载: {s['ddr_l']:>3}%",
                "-------------------------------------------------------------------------------------",
                f"  温度监控 : " + " | ".join([f"{k[:3]}:{v}°C" for k, v in s['temps'].items()]),
                "=====================================================================================",
                "  (按 Ctrl+C 退出监控)"
            ]
            sys.stdout.write("\n".join(output) + "\n")
            sys.stdout.flush()
            time.sleep(1)
    except KeyboardInterrupt:
        pass

def run_logger(mon, log_path=None):
    """日志记录模式 (CSV格式)"""
    if log_path is None or os.path.isdir(log_path):
        sensor_dir = os.path.join(log_path if log_path else ".", "sensor")
        os.makedirs(sensor_dir, exist_ok=True)
        filename = datetime.datetime.now().strftime('%Y-%m-%d_%H-%M-%S_RK3588.csv')
        log_file = os.path.join(sensor_dir, filename)
    else:
        log_file = log_path

    file_exists = os.path.isfile(log_file)
    print(f"开始记录日志到: {log_file}")

    try:
        with open(log_file, 'a') as f:
            while True:
                s = mon.get_stats()
                if not file_exists:
                    header = "Time,CPU_Load,CPU_Freq_0,CPU_Freq_1,CPU_Freq_2,CPU_Freq_3,CPU_Freq_4,CPU_Freq_5,CPU_Freq_6,CPU_Freq_7,GPU_Freq,GPU_Load,NPU_Freq,NPU_Load,DDR_Freq,DDR_Load," + ",".join(s['temps'].keys()) + "\n"
                    f.write(header)
                    file_exists = True

                row = f"{s['time']},{sum(s['loads'].values())/8:.1f},{','.join(s['freqs'])},{s['gpu_f']},{s['gpu_l']},{s['npu_f']},{s['npu_l']},{s['ddr_f']},{s['ddr_l']}," + ",".join(s['temps'].values()) + "\n"
                f.write(row)
                f.flush()
                time.sleep(1)
    except KeyboardInterrupt:
        print("\n停止记录。")

if __name__ == "__main__":
    if os.geteuid() != 0:
        print("⚠️  建议使用 sudo 运行，否则 NPU 负载可能无法读取。")
    monitor = RKMonitor()
    if len(sys.argv) > 1:
        if sys.argv[1] in ["-v", "--view"]:
            run_viewer(monitor)
        elif sys.argv[1] in ["-l", "--log"]:
            target = sys.argv[2] if len(sys.argv) > 2 else "."
            run_logger(monitor, target)
        else:
            print("用法: python3 rk_monitor.py [-v | -l <路径>]")
    else:
        print("用法: python3 rk_monitor.py [-v | -l <路径>]")

# Windows EXE 使用说明

此程序可在 Windows 64 位电脑上运行，无需安装或购买 MATLAB。目标电脑仍需免费的 MATLAB Runtime R2023a（9.14），更新级别须与编译版本兼容。

## 安装和启动

1. 从本仓库 Releases 下载 CAINI7_EIT_Setup.exe。
2. 运行安装程序。联网安装包会从 MathWorks 下载并安装所需 Runtime；首次安装耗时取决于网络。
3. 从安装目录启动 eit71_noser_upper_pc_app.exe。首次启动需要解压程序资源，会比后续启动慢。
4. 设置实际 COM 口，选择 raw872、小端、115200 / 8N1，点击发送 FF 并采集一周期。

如下载的是 EXE 压缩包，请先安装匹配的 Runtime，再解压整个目录并启动 EXE，不要直接在压缩包中运行。

## 离线检查

用界面的“导入实测HEX / BIN”打开随包提供的 caini7_sample_3488.hex。正确结果为 872 个 float，包含 832 个成像电测量、32 个温度、4 个压力和4个探杆电压；温度范围为 21.5–22.25，压力保留原始负值。

## 成像范围

完整发行包包含旧模拟成像模型和模拟日志。新硬件数据目前支持采集、拆分、显示和保存。旧 Jacobian 为 6700 行，与新硬件 836 个电测量不匹配；真实硬件 NOSER 成像仍需新模型和电流、模拟链路标定。

## 重新构建

在安装并许可 MATLAB Compiler 的 Windows MATLAB R2023a 中执行：

~~~matlab
build_eit71_noser_upper_pc_app
% 从源码仓库构建时，指定外部大型模型路径：
build_eit71_noser_upper_pc_app('web', 'D:/models/seafloor_core_hydrate_internal_probe_eit_result.mat')
% 为完全离线的目标电脑捆绑 Runtime（下载和安装包均较大）：
build_eit71_noser_upper_pc_app('installer')
~~~

输出到 build_eit71_noser_app/application 与 installer_web（或 installer_installer）。模型不在源码仓库内，未提供模型时会明确警告，只影响旧模拟成像。

## 本次验证

编译后的 EXE 已通过真实3488字节样例导入、MAT保存及全部872个数值逐值比对，并通过内置旧模型的单周期 NOSER 模拟重建。测试在开发电脑上使用 MATLAB 安装目录中的运行库完成；尚未在无 MATLAB 的干净电脑上实测安装包，也未进行真实串口设备联机测试。

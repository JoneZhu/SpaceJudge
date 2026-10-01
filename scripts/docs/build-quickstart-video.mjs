// Turn the privacy-reviewed, single-window recordings into a captioned guide.
// No fabricated application states, generated voices, or speed claims.
import { mkdirSync, existsSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';

const [sourceArgument, outputArgument] = process.argv.slice(2);
assert(sourceArgument && outputArgument, 'usage: node build-quickstart-video.mjs RECORDING_DIRECTORY NEW_OUTPUT_DIRECTORY');
const source = resolve(sourceArgument), output = resolve(outputArgument);
assert(!existsSync(output), 'Output must be a fresh directory; published media must not be silently overwritten');
for (const name of ['raw-2.mp4', 'navigation.mp4']) assert(existsSync(join(source, name)), `Missing ${name}`);
const font = '/System/Library/Fonts/STHeiti Medium.ttc';
assert(existsSync(font), 'Requires macOS STHeiti Medium font (font is not redistributed)');
mkdirSync(output, { recursive: true });
const working = join(output, 'work');
mkdirSync(working);

const steps = [
  { file: 'raw-2.mp4', start: 1, duration: 6, number: '01', title: '选择扫描范围', lines: ['启动页选择文件夹', '或整个磁盘。', '', '首次体验建议先选', '一个熟悉的小目录。'] },
  { file: 'raw-2.mp4', start: 76, duration: 8, number: '02', title: '一眼看清占用', lines: ['方块越大，占用越大。', '扫描结果逐步出现。', '', '颜色只用于区分目录，', '不表示能否删除。'] },
  { file: 'navigation.mp4', start: 51, duration: 8, number: '03', title: '逐层找到大项', lines: ['双击目录，进入查看。', '单击可选中或展开。', '', '点面包屑、返回键，', '回到上层继续浏览。'] },
  { file: 'navigation.mp4', start: 70, duration: 5, number: '04', title: '需要清理建议？', lines: ['对目录打开右键菜单，', '选择“用 Codex 分析”。', '', '也可查看信息，或', '在 Finder 中定位。'] },
  { file: 'navigation.mp4', start: 97, duration: 7, number: '04', title: '先检查分析草稿', lines: ['核对范围与上下文，', '再打开 Codex 草稿。', '', '需另行安装 Codex；', '不会自动发送或清理。'] },
  { file: 'navigation.mp4', start: 161, duration: 12, number: '05', title: '刷新，继续分析', lines: ['外部处理后按 Cmd+R，', '更新整个原扫描范围。', '', '保留当前浏览位置，', '比较目录占用变化。'] },
  { file: 'navigation.mp4', start: 180, duration: 5, number: 'END', title: '先看清，再决定', lines: ['SpaceJudge 只读扫描，', '不会替你删除文件。', '', '演示将测试文件移出', '范围，并未释放磁盘。'] },
];
function run(args) {
  const result = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-nostdin', ...args], { stdio: 'inherit' });
  assert.equal(result.status, 0, 'ffmpeg failed');
}
function text(label, index, x, y, size, color) {
  const file = join(working, `text-${index}.txt`);
  writeFileSync(file, label);
  return `drawtext=fontfile='${font}':textfile='${file}':x=${x}:y=${y}:fontsize=${size}:fontcolor=${color}`;
}
let textIndex = 0;
const clips = [];
for (const [index, step] of steps.entries()) {
  const captionFilters = [
    text('SpaceJudge', textIndex++, 42, 58, 39, '0x204a36'),
    text('一分钟上手', textIndex++, 42, 116, 25, '0x5e7768'),
    'drawbox=x=42:y=181:w=76:h=5:color=0x31a46c:t=fill',
    text(step.number, textIndex++, 40, 232, 67, '0x31a46c'),
    text(step.title, textIndex++, 42, 333, 33, '0x204a36'),
    ...step.lines.map((line, i) => text(line || ' ', textIndex++, 42, 414 + i * 43, 26, '0x415c4b')),
    text('真实应用 · 合成测试文件', textIndex++, 42, 872, 20, '0x667d6d'),
    text('占用 ≠ 可释放空间', textIndex++, 42, 917, 22, '0x667d6d'),
  ];
  const graph = `[0:v]fps=15,scale=1100:918:flags=lanczos,setsar=1,pad=1600:1000:480:40:color=0xf2f6f3,${captionFilters.join(',')},format=yuv420p[v]`;
  const clip = join(working, `clip-${index}.mp4`);
  run(['-ss', String(step.start), '-i', join(source, step.file), '-t', String(step.duration),
    '-filter_complex', graph, '-map', '[v]', '-an', '-c:v', 'libx264', '-preset', 'medium', '-crf', '22',
    '-movflags', '+faststart', clip]);
  clips.push(clip);
  console.log(`Rendered step ${index + 1}/${steps.length}`);
}
const concat = join(working, 'concat.txt');
writeFileSync(concat, clips.map(file => `file '${file.replaceAll("'", "'\\''")}'`).join('\n'));
const video = join(output, 'spacejudge-quickstart.mp4');
run(['-f', 'concat', '-safe', '0', '-i', concat, '-c', 'copy', '-movflags', '+faststart', video]);
run(['-i', video, '-filter_complex', '[0:v]fps=6,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=80:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle', '-loop', '0', join(output, 'spacejudge-quickstart.gif')]);
run(['-ss', '19', '-i', video, '-frames:v', '1', join(output, 'spacejudge-quickstart-poster.png')]);
writeFileSync(join(output, 'edit-plan.json'), JSON.stringify({ version: '0.5.2', durationSeconds: steps.reduce((sum, step) => sum + step.duration, 0), audio: false, source: 'Real single-window recordings; synthetic fixture; waiting time trimmed; not a benchmark', steps }, null, 2));
console.log(`Finished: ${video}`);

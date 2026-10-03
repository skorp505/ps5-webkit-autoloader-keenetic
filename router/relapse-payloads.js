// Автоотправка пейлоадов на elfldr после того, как он поднялся на 9021.
//
// Файл статический, список пейлоадов берётся из payloads.json рядом с index.html
// (его кладёт install.sh). Отправка идёт с самой приставки в 127.0.0.1:9021:
// из браузера сокеты недоступны, поэтому используется примитив из эксплоита.
//
// Код отправки повторяет proven-реализацию из ранних версий Relapse (MIT,
// ntfargo/Relapse-Exploit) — там он жил в kexp.js как loadOptionalPayloads().

import { int64 } from "./utils/int64.js";

const PROT_RW = 0x3;
const MAP_PRIVATE_ANON = 0x1002;
const AF_INET_SOCK_STREAM = 0x3d230210; // 0x3d AF_INET | (0x1 SOCK_STREAM << 16)
const LOOPBACK = 0x0100007f;             // 127.0.0.1
const ELFDR_PORT = 9021;
const CHUNK = 0x10000;
const CONNECT_ATTEMPTS = 40;

// SYS_MMAP, SYS_SOCKET, SYS_CONNECT, SYS_WRITE, SYS_CLOSE — глобалы из
// src/utils/syscalls.js, который index.html подключает обычным скриптом.

function readU32(bytes, offset) {
  return (bytes[offset] | (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

async function loadList() {
  try {
    const response = await fetch("payloads.json");
    if (!response.ok) return [];
    const list = await response.json();
    return Array.isArray(list) ? list.filter((name) => typeof name === "string") : [];
  } catch {
    return [];
  }
}

async function mapElf(name, p, chain) {
  const response = await fetch("payloads/" + name);
  if (!response.ok) throw new Error("HTTP " + response.status);
  const elf = new Uint8Array(await response.arrayBuffer());
  if (elf.length < 0x1000 || readU32(elf, 0) !== 0x464c457f)
    throw new Error("not an ELF");

  const size = (elf.length + 0x3fff) & ~0x3fff;
  const base = await chain.syscall(SYS_MMAP, 0, size, PROT_RW, MAP_PRIVATE_ANON, -1, 0);
  if (base.low >>> 0 === 0xffffffff || base.low < 0x10000)
    throw new Error("mmap failed");

  const dwords = elf.length & ~3;
  for (let offset = 0; offset < dwords; offset += 4)
    p.write4(base.add32(offset), readU32(elf, offset));
  for (let offset = dwords; offset < elf.length; offset++)
    p.write1(base.add32(offset), elf[offset]);

  if (p.read4(base) >>> 0 !== 0x464c457f)
    throw new Error("copy to memory failed");

  return { base, size: elf.length };
}

async function connectToElfldr(p, chain) {
  const address = p.malloc(16);
  p.write8(address, new int64(0, 0));
  p.write8(address.add32(8), new int64(0, 0));
  p.write4(address, AF_INET_SOCK_STREAM);
  p.write4(address.add32(4), LOOPBACK);

  for (let attempt = 0; attempt < CONNECT_ATTEMPTS; attempt++) {
    const socket = await chain.syscall(SYS_SOCKET, 2, 1, 0);
    const fd = socket.low | 0;
    if (fd >= 0) {
      const connected = await chain.syscall(SYS_CONNECT, fd, address, 16);
      if ((connected.low >>> 0) === 0) return fd;
      await chain.syscall(SYS_CLOSE, fd);
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw new Error("elfldr is not listening on port " + ELFDR_PORT);
}

async function sendElf(name, mapped, p, chain) {
  const fd = await connectToElfldr(p, chain);
  try {
    for (let offset = 0; offset < mapped.size;) {
      const length = Math.min(CHUNK, mapped.size - offset);
      const written = (await chain.syscall(SYS_WRITE, fd, mapped.base.add32(offset), length)).low | 0;
      if (written <= 0) throw new Error("socket write failed");
      offset += written;
    }
  } finally {
    await chain.syscall(SYS_CLOSE, fd);
  }
  return name;
}

export async function sendPayloads(p, chain, log) {
  const list = await loadList();
  if (list.length === 0) {
    log("no payloads in payloads.json", "info");
    return [];
  }

  const sent = [];
  for (const name of list) {
    try {
      await sendElf(name, await mapElf(name, p, chain), p, chain);
      sent.push(name);
      log(name + " sent", "success");
    } catch (error) {
      log(name + ": " + (error instanceof Error ? error.message : String(error)), "error");
    }
  }
  return sent;
}
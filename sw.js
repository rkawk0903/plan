"use strict";

const APP_VERSION = "380";
const CACHE_NAME = `wedding-planner-v${APP_VERSION}-shell`;
const RUNTIME_CACHE = `wedding-planner-v${APP_VERSION}-runtime`;
const SUPABASE_URL = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.116.0/dist/umd/supabase.js";
const NAVIGATION_TIMEOUT_MS = 5000;
const APP_SHELL = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./icons/icon-180.png",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
];

async function fetchFresh(request) {
  return fetch(new Request(request, { cache: "reload" }));
}

async function safePut(cacheName, request, response) {
  try {
    const cache = await caches.open(cacheName);
    await cache.put(request, response);
  } catch (error) {
    // Cache quota/write failures must never turn a successful network response into an offline failure.
    console.warn("service worker cache write failed", error);
  }
}

async function fetchWithTimeout(request, timeoutMs = NAVIGATION_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(new Request(request, { signal: controller.signal, cache: "no-store" }));
  } finally {
    clearTimeout(timer);
  }
}

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    for (const url of APP_SHELL) {
      const response = await fetchFresh(url);
      if (!response.ok) throw new Error(`precache failed: ${url} (${response.status})`);
      await safePut(CACHE_NAME, url, response);
    }
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(
      keys
        .filter((key) => key.startsWith("wedding-planner-") && key !== CACHE_NAME && key !== RUNTIME_CACHE)
        .map((key) => caches.delete(key)),
    );
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);

  // Pinned Supabase UMD is lazy-loaded by the app. Cache it after the first successful online load so
  // future offline launches can still restore a session without blocking the application shell.
  if (url.href === SUPABASE_URL) {
    event.respondWith((async () => {
      const cached = await caches.match(request, { ignoreSearch: false });
      if (cached) return cached;
      const response = await fetch(request);
      if (response.ok || response.type === "opaque") {
        await safePut(RUNTIME_CACHE, request, response.clone());
      }
      return response;
    })());
    return;
  }

  if (url.origin !== self.location.origin || url.pathname.endsWith("/sw.js")) return;

  if (request.mode === "navigate") {
    event.respondWith((async () => {
      try {
        const response = await fetchWithTimeout(request);
        if (response.ok) await safePut(CACHE_NAME, "./index.html", response.clone());
        return response;
      } catch {
        return (
          (await caches.match("./index.html", { ignoreSearch: true })) ||
          (await caches.match("./", { ignoreSearch: true })) ||
          Response.error()
        );
      }
    })());
    return;
  }

  event.respondWith((async () => {
    const cached = await caches.match(request, { ignoreSearch: false });
    if (cached) return cached;
    const response = await fetch(request);
    if (response.ok) await safePut(RUNTIME_CACHE, request, response.clone());
    return response;
  })());
});

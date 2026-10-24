const header = document.querySelector("[data-header]");
const menuToggle = document.querySelector("[data-menu-toggle]");
const menu = document.querySelector("[data-menu]");
const lightbox = document.querySelector("[data-lightbox-dialog]");
const lightboxImage = document.querySelector("[data-lightbox-image]");
const lightboxClose = document.querySelector("[data-lightbox-close]");

// Marquees loop by scrolling two copies of their items.
document.querySelectorAll("[data-marquee] .marquee-track").forEach((track) => {
  Array.from(track.children).forEach((item) => {
    const copy = item.cloneNode(true);
    copy.setAttribute("aria-hidden", "true");
    track.appendChild(copy);
  });
});

// Chinese copy is a static page (zh/index.html, built by scripts/build-site-zh.mjs
// from scripts/site-zh.json) so search engines index it as Chinese.

document.querySelectorAll("[data-year]").forEach((node) => {
  node.textContent = new Date().getFullYear();
});

const updateHeader = () => {
  header?.classList.toggle("scrolled", window.scrollY > 24);
};

updateHeader();
window.addEventListener("scroll", updateHeader, { passive: true });

menuToggle?.addEventListener("click", () => {
  const nextState = menuToggle.getAttribute("aria-expanded") !== "true";
  menuToggle.setAttribute("aria-expanded", String(nextState));
  menu?.classList.toggle("open", nextState);
  document.body.classList.toggle("menu-open", nextState);
});

menu?.querySelectorAll("a").forEach((link) => {
  link.addEventListener("click", () => {
    menuToggle?.setAttribute("aria-expanded", "false");
    menu.classList.remove("open");
    document.body.classList.remove("menu-open");
  });
});

const openLightbox = (source) => {
  if (!lightbox || !lightboxImage) return;
  lightboxImage.src = source;
  if (typeof lightbox.showModal === "function") {
    lightbox.showModal();
  }
};

document.querySelectorAll("[data-lightbox]").forEach((button) => {
  button.addEventListener("click", () => openLightbox(button.dataset.lightbox));
});

lightboxClose?.addEventListener("click", () => lightbox?.close());

lightbox?.addEventListener("click", (event) => {
  if (event.target === lightbox) lightbox.close();
});

lightbox?.addEventListener("close", () => {
  if (lightboxImage) lightboxImage.src = "";
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && menu?.classList.contains("open")) {
    menuToggle?.setAttribute("aria-expanded", "false");
    menu.classList.remove("open");
    document.body.classList.remove("menu-open");
  }
});

// Sections fade up once as they enter the viewport.
const revealTargets = document.querySelectorAll(".reveal");
if ("IntersectionObserver" in window) {
  const revealObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("in-view");
        revealObserver.unobserve(entry.target);
      });
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.08 }
  );
  revealTargets.forEach((target) => revealObserver.observe(target));
} else {
  revealTargets.forEach((target) => target.classList.add("in-view"));
}

// Spotlight cards: the light follows the pointer.
document.querySelectorAll(".spotlight").forEach((card) => {
  card.addEventListener("pointermove", (event) => {
    const rect = card.getBoundingClientRect();
    card.style.setProperty("--mx", `${event.clientX - rect.left}px`);
    card.style.setProperty("--my", `${event.clientY - rect.top}px`);
  });
});

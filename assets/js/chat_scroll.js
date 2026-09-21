const ChatScroll = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight
    this.capture = () => this.capturePosition()
    this.restore = () => this.restorePosition()
    document.addEventListener("chat:before-patch", this.capture)
    document.addEventListener("chat:after-patch", this.restore)
  },

  destroyed() {
    document.removeEventListener("chat:before-patch", this.capture)
    document.removeEventListener("chat:after-patch", this.restore)
  },

  capturePosition() {
    const viewport = this.el.getBoundingClientRect()
    const anchor = Array.from(this.el.querySelectorAll("[data-message-id]"))
      .find(message => message.getBoundingClientRect().bottom > viewport.top)

    this.position = {
      follow: this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight <= 32,
      scrollTop: this.el.scrollTop,
      anchorId: anchor?.id,
      offset: anchor ? anchor.getBoundingClientRect().top - viewport.top : 0,
    }
  },

  restorePosition() {
    const position = this.position
    if (!position) return

    if (position.follow) {
      this.el.scrollTop = this.el.scrollHeight
    } else {
      const anchor = position.anchorId && document.getElementById(position.anchorId)
      this.el.scrollTop = anchor
        ? this.el.scrollTop + anchor.getBoundingClientRect().top
          - this.el.getBoundingClientRect().top - position.offset
        : position.scrollTop
    }
    this.position = null
  },
}

export default ChatScroll

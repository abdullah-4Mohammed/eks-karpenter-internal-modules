<!-- frontend/App.vue -->
<template>
  <div>
    <h1>Frontend App</h1>
    <button @click="fetchBackend">Call Backend</button>
    <p>{{ message }}</p>
  </div>
</template>

<script>
export default {
  data() {
    return {
      message: ""
    };
  },
  methods: {
    async fetchBackend() {
      try {
        const response = await fetch(`${process.env.VUE_APP_API_URL}/api`);
        this.message = await response.text();
      } catch (error) {
        this.message = "Error connecting to backend";
      }
    }
  }
};
</script>

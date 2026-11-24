
const button = document.getElementById("fortune-button");
const fortuneText = document.getElementById("fortune-text");
const statusText = document.getElementById("status");

async function getFortune() {
    button.disabled = true;
    statusText.textContent = "";

    try {
        const response = await fetch("/fortune");

        if (!response.ok) {
            throw new Error("Server unavailable");
        }

        const data = await response.json();

        fortuneText.textContent = data.fortune;

    } catch (error) {
        statusText.textContent =
            "Could not load a fortune. Please try again.";
    } finally {
        button.disabled = false;
    }
}

button.addEventListener("click", getFortune);

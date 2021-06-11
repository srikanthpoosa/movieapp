const apiUrl =
  "https://api.themoviedb.org/3/discover/movie?sort_by=popularity.desc&api_key=04c35731a5ee918f014970082a0088b1&page=1";
const searchApi =
  "https://api.themoviedb.org/3/search/movie?&api_key=04c35731a5ee918f014970082a0088b1&query=";
const imagePath = "Https://image.tmdb.org/t/p/w1280/";
const main = document.querySelector(".main");
const form = document.getElementById("form");
const search = document.querySelector(".search");

form.addEventListener("submit", (e) => {
  e.preventDefault();
  const searchTerm = search.value;
  console.log("searchTerm", searchTerm);
  const searchingMovies = getSearchMovies(searchTerm);
});

async function getSearchMovies(searchTerm) {
  const res = await fetch(searchApi + searchTerm);
  const resData = await res.json();
  showMovies(resData);
}

getMovieData();

async function getMovieData(term = "") {
  const res = await fetch(apiUrl);
  const resData = await res.json();
  console.log("getMovieData -> resData", resData);
  showMovies(resData);
}

function showMovies(resData) {
  main.innerHTML = "";
  resData.results.forEach((movi) => {
    // console.log('getMovieData -> movi', movi);
    const image_src = imagePath + movi.poster_path;

    const mov = document.createElement("div");
    mov.classList.add("movie");
    mov.innerHTML = `
        <img src="${image_src}" alt="">
        <div class="movie-info">
            <h3>${movi.title}</h3>
            <span class= "${getColor(movi.vote_average)}">${
      movi.vote_average
    }</span>
        </div>
        <div class="overview">${movi.overview}</div>
        `;
    main.appendChild(mov);
    //console.log('getMovieData -> mv_image.src', mv_image.src);
  });
}

function getColor(vote) {
  if (vote >= 7) {
    return "green";
  } else if (vote >= 6) {
    return "orange";
  } else {
    return "red";
  }
}

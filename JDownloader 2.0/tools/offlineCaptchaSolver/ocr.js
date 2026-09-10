var Jimp = require('jimp'); //For image processing
var fs = require('fs');
var path = require('path');
const { execSync } = require('child_process');
const { EOL } = require('os');

const Pixelizer = require('image-pixelizer');
var white = Jimp.rgbaToInt(255, 255, 255, 255);
var red = Jimp.rgbaToInt(255, 0, 0, 255);
var black = Jimp.rgbaToInt(0, 0, 0, 255);

const DEBUG = process.env.DEBUG === 'true';
const darknetExec = (process.platform === 'win32' ? 'darknet_no_gpu.exe' : './darknet');

var what2Scan = process.argv[2] || "keep2share.cc"; //Start parameter
var inputPic = process.env.CAPTCHA_INPUT || process.argv[3] || 'input.gif';
var resultFile = process.env.CAPTCHA_OUTPUT || process.argv[4] || 'result.txt';
var logFile = process.env.CAPTCHA_LOG || 'log.txt';

console.log("Running ->", what2Scan, "Input:", inputPic);

function failSolve(reason) {
    console.error(`[CaptchaSolver] ${reason}`);
    try {
        if (fs.existsSync(resultFile)) {
            fs.unlinkSync(resultFile);
        }
    } catch (e) {
        // ignore
    }
    process.exit(1);
}

if (what2Scan == "keep2share.cc") {
    console.log("keep2share.cc");
    getKeep2share(inputPic, function (content) {
        try {
            fs.writeFileSync(resultFile, content["text"].toString());
            fs.writeFileSync(logFile, JSON.stringify(content, false, 2));
            console.log("Solved:", content["text"], `(confidence: ${content["confidence"]}%)`);
            process.exit(0);
        } catch (err) {
            failSolve("Failed writing result file: " + err.message);
        }
    });
} else if (what2Scan == "filejoker.net") {
    console.log(what2Scan);
    getFilejoker(inputPic, function (content) {
        try {
            fs.writeFileSync(resultFile, content["text"].toString());
            fs.writeFileSync(logFile, JSON.stringify(content, false, 2));
            console.log("Solved:", content["text"]);
            process.exit(0);
        } catch (err) {
            failSolve("Failed writing result file: " + err.message);
        }
    });
} else {
    failSolve("No function found for: " + what2Scan);
}

//Solving keep2share.cc new captchas
function getKeep2share(file, callback) {
    if (!fs.existsSync(file)) {
        failSolve("Captcha input file does not exist: " + file);
    }

    Jimp.read(file).then(image => {
        image.rgba(false).greyscale();

        const data = image.bitmap.data;
        for (let i = 0; i < data.length; i += 4) {
            if (data[i] < 253) {
                data[i] = 0;
                data[i + 1] = 0;
                data[i + 2] = 0;
            }
        }


        const darknetDir = path.join(__dirname, 'darknet64');
        const tempImgPath = path.join(darknetDir, 'temp.jpg');

        image.write(tempImgPath, function (err) {
            if (err) {
                failSolve("Failed to write temporary image for darknet: " + err);
            }

            try {
                let cmd = darknetExec + ' detector test data/obj.data yolov4-tiny-custom.cfg yolov4-tiny-custom_last.weights -dont_show -ext_output temp.jpg';
                let result = execSync(cmd, {
                    cwd: darknetDir,
                    stdio: ['pipe', 'pipe', 'pipe']
                });
                let resultString = result.toString('utf8');

                var lines = resultString.split(/\r?\n/);
                
                var valdResA = [];
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim();
                    if (line.indexOf(":") !== -1 && line.indexOf("%") !== -1) {
                        // Supports both with and without -ext_output:
                        // "c: 95%" or "c: 95% (left_x: 120 top_y: 50 width: 30 height: 40)"
                        var match = line.match(/^([a-zA-Z0-9]):\s*(\d+)%(?:\s*\(left_x:\s*([-\d]+))?/);
                        if (match) {
                            var charVal = match[1];
                            var probVal = parseFloat(match[2]);
                            var leftX = match[3] !== undefined ? parseInt(match[3], 10) : i;
                            valdResA.push({ c: charVal, p: probVal, x: leftX });
                        }
                    }
                }

                for (var i = valdResA.length - 1; i >= 0; i--) { //Remove "I" because big "i" and small "L" -> "l" have the same char in this font
                    if (valdResA[i]["c"] == "I") {
                        valdResA.splice(i, 1);
                    }
                }

                while (valdResA.length > 6) { //Remove letters with lowest props
                    var sma = 100; //Smallest confidence
                    var index = 0; //Index of char with smallest confidence
                    for (var i = 0; i < valdResA.length; i++) {
                        if (sma > valdResA[i]["p"]) {
                            sma = valdResA[i]["p"];
                            index = i;
                        }
                    }
                    valdResA.splice(index, 1);
                }

                // Strict validation: Keep2Share captchas must have exactly 6 characters
                if (valdResA.length !== 6) {
                    failSolve(`Solving impossible: detected ${valdResA.length} character(s) (expected 6). Falling back to 2Captcha.`);
                }

                // Sort the 6 characters spatially from left to right by bounding box X coordinate
                valdResA.sort((a, b) => a.x - b.x);

                var text = "";
                var totalConfidence = 0;
                for (var i = 0; i < valdResA.length; i++) {
                    text += valdResA[i]["c"];
                    totalConfidence += parseFloat(valdResA[i]["p"]);
                }
                var confidence = Math.round(totalConfidence / 6);

                // Strict confidence validation: reject low confidence garbage
                if (confidence < 50) {
                    failSolve(`Solving impossible: average confidence too low (${confidence}% < 50%). Falling back to 2Captcha.`);
                }

                callback({ host: what2Scan, text: text, confidence: confidence });
            } catch (execErr) {
                failSolve("Darknet execution error: " + execErr.message);
            }
        });

    }).catch(err => {
        failSolve("Failed to load captcha image: " + (err ? err.message : err));
    });
}


function getFilejoker(file, callback) {
    if (!fs.existsSync(file)) {
        failSolve("Captcha input file does not exist: " + file);
    }

    Jimp.read(file).then(image => {
        var mainImg = "";
        var solution = "";
        var confidence = {};

        let gImgCnt = 0;
        for (var yOrg = 0; yOrg < 5; yOrg++) {
            for (var xOrg = 0; xOrg < 5; xOrg++) {
                let xxxx = xOrg * 50;
                let yyyy = yOrg * 50;
                if (yOrg == 0 && xOrg > 0) {
                    //Dont read the black ones
                } else {
                    if (xxxx < image.bitmap.width - 1 && yyyy < image.bitmap.height - 1) {
                        let CPimage = image.clone();
                        CPimage.crop(xxxx, yyyy, 50, 50);
                        if (DEBUG) CPimage.write("out" + gImgCnt + "_0.png");
                        CPimage.convolute(kernels.blur);

                        let inputBitmap = new Pixelizer.Bitmap(
                            CPimage.bitmap.width,
                            CPimage.bitmap.height,
                            CPimage.bitmap.data
                        );

                        let options = new Pixelizer.Options()
                            .setPixelSize(1)
                            .setColorDistRatio(0.1)
                            .setClusterThreshold(0.1)
                            .setMaxIteration(10)
                            .setNumberOfColors(3);
                        let outputBitmap = new Pixelizer(inputBitmap, options).pixelize();

                        CPimage.bitmap.width = outputBitmap.width;
                        CPimage.bitmap.height = outputBitmap.height;
                        CPimage.bitmap.data = outputBitmap.data;

                        if (DEBUG) CPimage.write("out" + gImgCnt + "_1.png");

                        fillBucket(CPimage, 25, 25, white);

                        if (DEBUG) CPimage.write("out" + gImgCnt + "_2.png");
                        let maxDistance = 0;
                        var fx = 0;
                        var fy = 0;

                        for (var x = 0; x < CPimage.bitmap.width; x++) {
                            for (var y = 0; y < CPimage.bitmap.height; y++) {
                                let currentColor = CPimage.getPixelColor(x, y);
                                if (currentColor != white) {
                                    CPimage.setPixelColor(black, x, y);
                                } else {
                                    var d = distance(x, y, 25, 25);
                                    if (d > maxDistance) {
                                        maxDistance = d;
                                        fx = x;
                                        fy = y;
                                    }
                                }
                            }
                        }

                        if (DEBUG) CPimage.write("out" + gImgCnt + "_3.png");

                        var maxD = distance(50, 50, 25, 25);
                        var dDiv = maxD / maxDistance;

                        CPimage.resize(50 * dDiv, Jimp.AUTO);
                        if (DEBUG) CPimage.write("out" + gImgCnt + "_4.png");

                        let pixelCount = 0;
                        const pData = CPimage.bitmap.data;
                        for (let i = 0; i < pData.length; i += 4) {
                            if (pData[i] !== 0 || pData[i + 1] !== 0 || pData[i + 2] !== 0) {
                                pixelCount++;
                                if (DEBUG) {
                                    pData[i] = 255;
                                    pData[i + 1] = 0;
                                    pData[i + 2] = 0;
                                }
                            }
                        }

                        let localSolution = getGeoFromPixelCnt(pixelCount);
                        if (gImgCnt == 0) {
                            mainImg = localSolution;
                        } else if (mainImg == localSolution) {
                            solution = solution == "" ? gImgCnt : solution + "," + gImgCnt;
                        }
                        if (DEBUG) console.log(gImgCnt, localSolution, pixelCount);
                        confidence[gImgCnt] = localSolution + " " + pixelCount;
                        if (DEBUG) CPimage.write("out" + gImgCnt + "_5.png");

                        gImgCnt++;
                    }
                }
            }
        }

        if (!solution || solution === "") {
            failSolve("FileJoker: no matching geometric shape found. Falling back to 2Captcha.");
        }

        callback({ host: what2Scan, text: solution, confidence: confidence });

        if (DEBUG) {
            for (var i = 0; i < 20; i++) {
                for (var k = 0; k < 10; k++) {
                    let p = "out" + i + "_" + k + ".png";
                    if (fs.existsSync(p)) {
                        fs.unlinkSync(p);
                    }
                }
            }
        }
    }).catch(err => {
        failSolve("Failed processing filejoker captcha: " + (err ? err.message : err));
    });


    const distance = (x1, y1, x2, y2) => Math.hypot(x2 - x1, y2 - y1);

    function fillBucket(image, startX, startY, newColor) { // Start painting with paint bucket tool starting from pixel specified by startX and startY
        const w = image.bitmap.width;
        const h = image.bitmap.height;
        const colorToReplace = image.getPixelColor(startX, startY);
        if (colorToReplace === newColor) return;

        const visited = new Uint8Array(w * h);
        const stackX = [startX];
        const stackY = [startY];

        while (stackX.length > 0) {
            const x = stackX.pop();
            const y = stackY.pop();

            if (x > 0 && x < w && y > 0 && y < h) {
                const idx = y * w + x;
                if (!visited[idx]) {
                    visited[idx] = 1;
                    if (image.getPixelColor(x, y) === colorToReplace) {
                        image.setPixelColor(newColor, x, y);
                        stackX.push(x + 1, x + 1, x + 1, x - 1, x - 1, x - 1, x);
                        stackY.push(y,     y + 1, y - 1, y,     y + 1, y - 1, y - 1);
                    }
                }
            }
        }
    }


    function getGeoFromPixelCnt(pixelCnt) {
        if (pixelCnt > 3850) {
            return "Circle"
        } else if (pixelCnt > 3300) {
            return "6 Corners"
        } else if (pixelCnt > 3000) {
            return "5 Corners"
        } else if (pixelCnt > 2500) {
            return "4 Corners"
        } else {
            return "3 Corners"
        }
    }

    const kernels =
    {
        emboss: [[-2, -1, 0], [-1, 1, 1], [0, 1, 2]],
        edgedetect: [[0, 1, 0], [1, -4, 1], [0, 1, 0]],
        edgeenhance: [[0, 0, 0], [-1, 1, 0], [0, 0, 0]],
        blur: [[0.0625, 0.125, 0.0625], [0.125, 0.25, 0.125], [0.0625, 0.125, 0.0625]],
        // equivalent to {name: "blur", kernel: [[1/16, 1/8, 1/16],[1/8, 1/4, 1/8], [1/16, 1/8, 1/16]]},
        sharpen: [[0, -1, 0], [-1, 5, -1], [0, -1, 0]]
    }
}

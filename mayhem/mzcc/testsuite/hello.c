int add(int a, int b) {
    return a + b;
}

int classify(int n) {
    if (n > 10) {
        return 1;
    } else {
        return 0;
    }
}

int main() {
    int a = add(3, 4);
    int b = a * 2 - 1;
    int big = classify(b);
    if (big) {
        printf("big\n");
    } else {
        printf("small\n");
    }
    return b;
}
